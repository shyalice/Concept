import SGAppGroupIdentifier // MARK: Swiftgram
import Foundation
import PasscodeCore
import UserNotifications
import SwiftSignalKit
import TelegramCore
import BuildConfig
import OpenSSLEncryptionProvider
import TelegramUIPreferences
import WebPBinding
import LottieBinding
import GZip
import UIKit
import Intents
import PersistentStringHash
import CallKit
import AppLockState
import NotificationsPresentationData
import RangeSet
import ConvertOpusToAAC
import CoreServices
import ImageIO
import UniformTypeIdentifiers

typealias CMJImage = UIImage

// MARK: - Public Namespace

/// A lightweight utility for turning ordinary bitmap images into ``NSAdaptiveImageGlyph`` (Apple “Genmoji”) objects.
///
/// ## Overview
/// The public API is minimal — a single call to generate a glyph and helper utilities for
/// de/serialising attributed strings.
///
/// ```swift
/// // Synchronous usage
/// let glyph = try Customoji.makeGlyph(
///     from: image,
///     description: "alt text",
///     cropToSquare: true
/// )
/// let attr = NSAttributedString(adaptiveImageGlyph: glyph, attributes: [:])
/// ```
///
/// ## Requirements
/// * iOS 18 / macOS 15
/// * Swift 5.10+
///
/// ## Topics
/// - Generating glyphs: ``makeGlyph(from:description:identifier:tileSizes:cropToSquare:heicQuality:)``
/// - Generating glyphs asynchronously: ``makeGlyphAsync(from:description:identifier:tileSizes:cropToSquare:heicQuality:)``
/// - Serialising: ``decompose(_:)`` / ``recompose(plain:ranges:blobs:)``
///
public struct Customoji {

    // MARK: Library-scoped Errors
    /// Errors that can be thrown by ``Customoji``.
    public enum Error: Swift.Error, LocalizedError {
        /// The input image is not square and ``makeGlyph(from:description:identifier:tileSizes:cropToSquare:heicQuality:)`` was called with `cropToSquare == false`.
        case nonSquare
        /// The longest side of the input image exceeds ``maxSide`` pixels (defaults to 4096).
        case imageTooLarge
        /// Failed to create an in-memory HEIC container via *Image I/O*.
        case heicDestinationCreationFailed
        /// Failed to finalise the HEIC container after writing all tiles.
        case heicFinalizeFailed
        /// Internal resize operation failed when generating a tile.
        case imageScaleFailed
        /// A `CGImage` representation could not be extracted from the source image.
        case cgImageUnavailable
        /// The `tileSizes` parameter was empty, not strictly ascending, contained duplicates, or exceeded the source size.
        case invalidTileSizes
        /// No tiles were generated — normally unreachable unless all requested sizes were invalid.
        case noTilesGenerated
        /// The current platform is neither UIKit- nor AppKit-based (unlikely in practice).
        case unsupportedPlatform
        /// The `heicQuality` parameter was outside the 0.0 … 1.0 range.
        case invalidHeicQuality
        /// Cropping or scaling to a square failed.
        case squareCropFailed

        /// Textual description suitable for presenting to users.
        public var errorDescription: String? {
            switch self {
            case .nonSquare: return "Input image must be square."
            case .imageTooLarge:
                return "Source image is too large to process safely."
            case .heicDestinationCreationFailed:
                return
                    "Failed to create an in-memory HEIC destination container."
            case .heicFinalizeFailed: return "Failed to finalize HEIC encoding."
            case .imageScaleFailed: return "Failed to rescale CGImage tile."
            case .cgImageUnavailable:
                return "Unable to obtain CGImage from the source image."
            case .invalidTileSizes:
                return
                    "Tile sizes must be unique, strictly ascending, and not exceed the source size."
            case .noTilesGenerated:
                return "No tiles were generated from the source image."
            case .unsupportedPlatform:
                return
                    "Unsupported platform when attempting to extract CGImage."
            case .invalidHeicQuality:
                return "HEIC quality must be between 0.0 and 1.0."
            case .squareCropFailed:
                return "Failed to create a square crop of the input image."
            }
        }
    }

    /// Default tile sizes (in pixels) officially used by Apple for Genmoji.
    public static let defaultTileSizes = [40, 64, 96, 160, 320]

    /// Maximum allowed side length (in pixels) to guard against excessive memory consumption.
    private static let maxSide = 4_096

    // MARK: - Synchronous Builder
    #if swift(>=5.10)
        @available(iOS 18.0, macCatalyst 18.0, macOS 15.0, *)
        /// Generates an ``NSAdaptiveImageGlyph`` synchronously on the **current** thread.
        ///
        /// - Parameters:
        ///   - image: Source image. Can be rectangular; see `cropToSquare`.
        ///   - description: A human-readable accessibility description (VoiceOver/Narrator).
        ///   - identifier: A globally unique content identifier. Defaults to a fresh UUID.
        ///   - tileSizes: Desired tile sizes, in pixels. Must be strictly ascending. Defaults to ``defaultTileSizes``.
        ///   - cropToSquare: When `true`, the central square area is cropped if the input image is not square.
        ///   - heicQuality: Lossy compression quality between `0.0` and `1.0`. Defaults to `0.8`.
        /// - Throws: ``Customoji/Error`` if validation or encoding fails.
        /// - Returns: A fully-formed glyph ready for attribution.
        static func makeGlyph(
            from image: CMJImage,
            description: String,
            identifier: String = UUID().uuidString,
            tileSizes: [Int] = defaultTileSizes,
            cropToSquare: Bool = false,
            heicQuality: CGFloat = 0.8
        ) throws -> NSAdaptiveImageGlyph {
            try validatePixelSide(of: image)
            let cg = try extractCGImage(from: image)

            return try coreMakeGlyph(
                from: cg,
                description: description,
                identifier: identifier,
                tileSizes: tileSizes,
                cropToSquare: cropToSquare,
                heicQuality: heicQuality
            )
        }
    #endif

    // MARK: - AttributedString Utilities
    #if swift(>=5.10)
        @available(iOS 18.0, macCatalyst 18.0, macOS 15.0, *)
        /// Breaks an ``NSAttributedString`` that may contain adaptive-image glyphs into three parts.
        ///
        /// This is handy when you need to **serialise** rich text for network transport or persistent
        /// storage, because `NSAdaptiveImageGlyph` itself is not `Codable`.
        ///
        /// ```swift
        /// let (plain, ranges, blobs) = Customoji.decompose(attrString)
        /// ```
        ///
        /// - Returns: A tuple where:
        ///   - plain: UTF-16 plain text.
        ///   - ranges: An array mapping text ranges to glyph identifiers.
        ///   - blobs: A dictionary mapping identifier → raw HEIC data.
        @inlinable
        public static func decompose(_ attr: NSAttributedString) -> (
            plain: String, ranges: [(NSRange, String)], blobs: [String: Data]
        ) {
            var ranges = [(NSRange, String)]()
            var blobs = [String: Data]()

            attr.enumerateAttribute(
                .adaptiveImageGlyph,
                in: NSRange(location: 0, length: attr.length)
            ) { value, range, _ in
                guard let g = value as? NSAdaptiveImageGlyph else { return }
                let id = g.contentIdentifier
                ranges.append((range, id))
                blobs[id] = blobs[id] ?? g.imageContent
            }

            return (attr.string, ranges, blobs)
        }

        @available(iOS 18.0, macCatalyst 18.0, macOS 15.0, *)
        /// Reassembles an attributed string previously produced by ``decompose(_:)``.
        ///
        /// - Parameters:
        ///   - plain: The plain UTF-16 text.
        ///   - ranges: An array of `(NSRange, identifier)` pairs.
        ///   - blobs: A dictionary of identifier → HEIC data. *Must* contain every identifier referenced by `ranges`.
        /// - Returns: A fully restored `NSAttributedString` with adaptive-image glyphs reinstated.
        public static func recompose(
            plain: String,
            ranges: [(NSRange, String)],
            blobs: [String: Data]
        ) -> NSAttributedString {
            let out = NSMutableAttributedString(string: plain)
            var cache = [String: NSAdaptiveImageGlyph]()

            ranges.forEach { (range, id) in
                if cache[id] == nil, let data = blobs[id] {
                    cache[id] = NSAdaptiveImageGlyph(imageContent: data)
                }
                if let glyph = cache[id] {
                    out.addAttribute(
                        .adaptiveImageGlyph,
                        value: glyph,
                        range: range
                    )
                }
            }
            return out
        }
    #endif

    // MARK: - Helper: Pixel-Side Validation
    /// Ensures that the image’s **longer edge** does not exceed ``maxSide`` pixels, guarding against
    /// excessive memory usage during HEIC encoding.
    private static func validatePixelSide(of image: CMJImage) throws {
        #if canImport(UIKit)
            let scale = image.scale == 0 ? 1 : image.scale
            let px = Int(max(image.size.width, image.size.height) * scale)
        #elseif canImport(AppKit)
            let px = Int(
                max(image.size.width, image.size.height)
                    * CGFloat(NSScreen.main?.backingScaleFactor ?? 1)
            )
        #endif
        guard px <= maxSide else { throw Error.imageTooLarge }
    }
}

// =============================================================
//  Below this line lies the internal implementation.
//  Public-facing symbols have already been documented above.
// =============================================================

// MARK: - Core Builder
@available(iOS 18.0, macCatalyst 18.0, macOS 15.0, *)
extension Customoji {
    @Sendable fileprivate static func coreMakeGlyph(
        from original: CGImage,
        description: String,
        identifier: String,
        tileSizes: [Int],
        cropToSquare: Bool,
        heicQuality: CGFloat
    ) throws -> NSAdaptiveImageGlyph {
        let cg = try ensureSquare(original, cropIfNeeded: cropToSquare)
        guard cg.width <= maxSide else { throw Error.imageTooLarge }

        let validSizes = try validatedTileSizes(tileSizes, max: cg.width)
        let data = try heicData(
            from: cg,
            id: identifier,
            description: description,
            tileSizes: validSizes,
            quality: heicQuality
        )
        return NSAdaptiveImageGlyph(imageContent: data)
    }
}

// MARK: - HEIC Encoder
@available(iOS 18.0, macCatalyst 18.0, macOS 15.0, *)
extension Customoji {
    fileprivate static func heicData(
        from cg: CGImage,
        id: String,
        description: String,
        tileSizes: [Int],
        quality: CGFloat
    ) throws -> Data {
        guard (0...1).contains(quality) else { throw Error.invalidHeicQuality }

        let destData = NSMutableData()
        guard
            let dest = CGImageDestinationCreateWithData(
                destData,
                UTType.heic.identifier as CFString,
                tileSizes.count,
                nil
            )
        else {
            throw Error.heicDestinationCreationFailed
        }

        // Attach Genmoji metadata
        let meta = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueWithPath(
            meta,
            nil,
            "tiff:\(kCGImagePropertyTIFFDocumentName)" as CFString,
            id as CFString
        )
        CGImageMetadataSetValueWithPath(
            meta,
            nil,
            "dc:description" as CFString,
            description as CFString
        )

        for (idx, side) in tileSizes.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            guard let img = cg.scaled(to: side) else {
                throw Error.imageScaleFailed
            }
            let opts =
                [kCGImageDestinationLossyCompressionQuality: quality]
                as CFDictionary
            if idx == 0 {
                CGImageDestinationAddImageAndMetadata(dest, img, meta, opts)
            } else {
                CGImageDestinationAddImage(dest, img, opts)
            }
        }

        guard CGImageDestinationFinalize(dest) else {
            throw Error.heicFinalizeFailed
        }
        return destData as Data
    }
}

// MARK: - CGImage Helpers
extension CGImage {
    /// Returns a copy whose longer edge equals `side` pixels. *Assumes the input is already square.*
    fileprivate func scaled(to side: Int) -> CGImage? {
        guard width != side else { return self }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let hasAlpha: Bool = {
            switch alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: return false
            default: return true
            }
        }()
        let bitmapInfo: UInt32 =
            hasAlpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue

        guard
            let ctx = CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: cs,
                bitmapInfo: bitmapInfo
            )
        else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }
}

// MARK: - Image Extraction Helpers
extension Customoji {
    fileprivate static func extractCGImage(from image: CMJImage) throws
        -> CGImage
    {
        #if canImport(UIKit)
            if let cg = (image as UIImage).cgImage { return cg }

            var rendered: CGImage?
            let work = { rendered = renderCGImage(image) }
            if Thread.isMainThread {
                work()
            } else {
                DispatchQueue.main.sync(execute: work)
            }
            if let cg = rendered { return cg }
        #elseif canImport(AppKit)
            var rect = CGRect(origin: .zero, size: image.size)
            if let cg = (image as NSImage).cgImage(
                forProposedRect: &rect,
                context: nil,
                hints: nil
            ) {
                return cg
            }
            if let tiff = (image as NSImage).tiffRepresentation,
                let rep = NSBitmapImageRep(data: tiff), let cg = rep.cgImage
            {
                return cg
            }
        #endif
        throw Error.cgImageUnavailable
    }

    #if canImport(UIKit)
        private static func renderCGImage(_ image: UIImage) -> CGImage? {
            precondition(Thread.isMainThread, "Must be on main thread")
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = image.scale == 0 ? 1 : image.scale
            fmt.opaque = false
            return UIGraphicsImageRenderer(size: image.size, format: fmt).image
            { _ in image.draw(at: .zero) }.cgImage
        }
    #endif
}

// MARK: - Square Enforcement
extension Customoji {
    fileprivate static func ensureSquare(_ cg: CGImage, cropIfNeeded: Bool)
        throws -> CGImage
    {
        guard cg.width == cg.height else {
            guard cropIfNeeded else { throw Error.nonSquare }

            let side = min(cg.width, cg.height)
            let rect = CGRect(
                x: (cg.width - side) / 2,
                y: (cg.height - side) / 2,
                width: side,
                height: side
            )

            if let cropped = cg.cropping(to: rect) { return cropped }
            if let scaled = cg.scaled(to: side) { return scaled }
            throw Error.squareCropFailed
        }
        return cg
    }
}

// MARK: - Tile Size Validation
extension Customoji {
    fileprivate static func validatedTileSizes(_ sizes: [Int], max: Int) throws
        -> [Int]
    {
        guard !sizes.isEmpty else { throw Error.invalidTileSizes }
        for (prev, curr) in zip(sizes, sizes.dropFirst()) where curr <= prev {
            throw Error.invalidTileSizes
        }
        guard sizes.allSatisfy({ $0 > 0 && $0 <= max }) else {
            throw Error.invalidTileSizes
        }
        return sizes
    }
}

