import Foundation
import UIKit
import CoreImage
import Display
import ComponentFlow
import AccountContext
import TelegramCore
import TelegramPresentationData
import PeerInfoCoverComponent

/// A passive backdrop: the avatar gallery, gift interactions and scroll ownership
/// stay in their existing nodes. No snapshotting, extra image requests or timer.
final class ConceptProfileBackdropView: UIView {
    private let cover = ComponentView<Empty>()
    private let photoContainer = UIView()
    private let photo = UIImageView()
    private let shade = UIView()
    private final class PreparedPhoto: NSObject {
        weak var source: UIImage?
        let image: UIImage
        let color: UIColor
        let luminance: CGFloat
        init(source: UIImage, image: UIImage, color: UIColor, luminance: CGFloat) {
            self.source = source
            self.image = image
            self.color = color
            self.luminance = luminance
        }
    }
    private static let photoCache: NSCache<NSString, PreparedPhoto> = {
        let cache = NSCache<NSString, PreparedPhoto>()
        cache.countLimit = 12
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()
    private static let photoQueue = DispatchQueue(label: "Concept.ProfilePhoto", qos: .userInitiated)
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let tone = CAGradientLayer()
    private weak var sourcePhoto: UIImage?
    private var photoGeneration: UInt = 0
    private var photoLuminance: CGFloat = 0.35
    private var coverLuminance: CGFloat = 0.35
    private var expanded = false
    private var hasCover = false
    private let themeFade = UIView()
    private var coverConfiguration: (PeerInfoCoverComponent.Subject?, CGSize, Bool, Bool)?
    private var toneConfiguration: (CGFloat, Bool)?

    public private(set) var dominantColor: UIColor?
    public private(set) var photoColor: UIColor?
    public private(set) var coverColor: UIColor?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.accessibilityElementsHidden = true
        self.clipsToBounds = true
        self.photo.contentMode = .scaleAspectFill
        self.photo.clipsToBounds = true
        self.photoContainer.addSubview(self.photo)
        self.tone.startPoint = CGPoint(x: 0.5, y: 0.0)
        self.tone.endPoint = CGPoint(x: 0.5, y: 1.0)
        self.tone.locations = [0.0, 0.38, 1.0]
        // The sharp photo owns the only photo-to-blur mask.
        self.addSubview(self.photoContainer)
        self.layer.addSublayer(self.tone)
        self.shade.backgroundColor = .black
        self.shade.alpha = 0.0
        self.addSubview(self.shade)
        self.addSubview(self.themeFade)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(context: AccountContext, peer: EnginePeer?, size: CGSize, avatarFrame: CGRect, image: UIImage?, expanded: Bool, enabled: Bool, theme: PresentationTheme, transition: ContainedViewLayoutTransition) {
        let subject: PeerInfoCoverComponent.Subject?
        if let status = peer?.emojiStatus, case .starGift = status.content {
            subject = .status(status)
        } else if let peer, peer.effectiveProfileColor != nil {
            subject = .peer(peer)
        } else { subject = nil }

        // The stock theme remains the accessibility fallback; never blur when
        // Reduce Transparency is on. The original header still owns its cover.
        let visible = enabled && !UIAccessibility.isReduceTransparencyEnabled
        transition.updateAlpha(layer: self.layer, alpha: visible ? 1.0 : 0.0)
        let effectiveSubject = visible ? subject : nil
        if self.coverConfiguration?.0 != effectiveSubject || self.coverConfiguration?.1 != size || self.coverConfiguration?.2 != theme.overallDarkAppearance || self.coverConfiguration?.3 != expanded {
            self.coverConfiguration = (effectiveSubject, size, theme.overallDarkAppearance, expanded)
            self.coverLuminance = Self.luminance(of: peer, context: context, isDark: theme.overallDarkAppearance)
            let coverSize = self.cover.update(
            transition: ComponentTransition(transition),
            component: AnyComponent(PeerInfoCoverComponent(
                context: context, subject: effectiveSubject, files: [:],
                isDark: theme.overallDarkAppearance,
                avatarCenter: avatarFrame.center, avatarSize: avatarFrame.size,
                avatarScale: 1.0, defaultHeight: size.height,
                gradientOnTop: true, avatarTransitionFraction: 0.0,
                patternTransitionFraction: 1.0
            )), environment: {}, containerSize: size
        )
            if let coverView = self.cover.view {
                if coverView.superview == nil { self.insertSubview(coverView, at: 0) }
                transition.updateFrame(view: coverView, frame: CGRect(origin: .zero, size: coverSize))
            }
        }
        if let coverView = self.cover.view { transition.updateAlpha(layer: coverView.layer, alpha: expanded ? 0.0 : 1.0) }
        self.expanded = expanded
        self.hasCover = subject != nil
        if let status = peer?.emojiStatus, case let .starGift(_, _, _, _, _, inner, outer, _, _) = status.content {
            let c1 = UIColor(rgb: UInt32(bitPattern: inner))
            let c2 = UIColor(rgb: UInt32(bitPattern: outer))
            self.coverColor = c1.mixedWith(c2, alpha: 0.5)
        } else if let peer, let profileColor = peer.effectiveProfileColor {
            let colors = context.peerNameColors.getProfile(profileColor, dark: theme.overallDarkAppearance)
            self.coverColor = colors.main
        } else {
            self.coverColor = nil
        }
        self.dominantColor = expanded || !self.hasCover ? self.photoColor : (self.coverColor ?? self.photoColor)
        if enabled, self.sourcePhoto !== image { self.preparePhoto(image) }
        self.updateTone(animated: transition.isAnimated)

        let bounds = CGRect(origin: CGPoint(), size: size)
        transition.updateFrame(view: self.photoContainer, frame: bounds)
        transition.updateFrame(view: self.photo, frame: bounds)
        transition.updateFrame(view: self.shade, frame: bounds)
        transition.updateFrame(view: self.themeFade, frame: bounds)
        transition.updateAlpha(layer: self.shade.layer, alpha: visible && (expanded || self.hasCover) ? 0.05 : 0.0)
        // The sharp gallery fades into the cached, strongly blurred color field.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.tone.frame = bounds
        CATransaction.commit()
        transition.updateAlpha(layer: self.photoContainer.layer, alpha: expanded ? 1.0 : 0.0)
        self.themeFade.backgroundColor = theme.list.blocksBackgroundColor
    }


    private static func luminance(_ color: UIColor) -> CGFloat {
        var r: CGFloat = 0.0, g: CGFloat = 0.0, b: CGFloat = 0.0, a: CGFloat = 0.0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0.35 }
        func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private static func luminance(of peer: EnginePeer?, context: AccountContext, isDark: Bool) -> CGFloat {
        if let status = peer?.emojiStatus, case let .starGift(_, _, _, _, _, inner, outer, _, _) = status.content {
            return (self.luminance(UIColor(rgb: UInt32(bitPattern: inner))) + self.luminance(UIColor(rgb: UInt32(bitPattern: outer)))) * 0.5
        }
        if let color = peer?.effectiveProfileColor {
            let colors = context.peerNameColors.getProfile(color, dark: isDark)
            return (self.luminance(colors.main) + self.luminance(colors.secondary ?? colors.main)) * 0.5
        }
        return 0.35
    }

    private func updateTone(animated: Bool = false) {
        let luminance = self.expanded ? self.photoLuminance : self.coverLuminance
        let strength = max(0.0, min(1.0, (luminance - 0.12) / 0.65))
        let visible = self.expanded || self.hasCover
        if self.toneConfiguration?.0 == luminance && self.toneConfiguration?.1 == visible { return }
        self.toneConfiguration = (luminance, visible)
        let previousColors = self.tone.presentation()?.colors ?? self.tone.colors
        let colors = [
            UIColor.black.withAlphaComponent(visible ? 0.08 + strength * 0.16 : 0.0).cgColor,
            UIColor.black.withAlphaComponent(visible ? 0.12 + strength * 0.22 : 0.0).cgColor,
            UIColor.black.withAlphaComponent(visible ? 0.16 + strength * 0.24 : 0.0).cgColor
        ]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.tone.colors = colors
        CATransaction.commit()
        if animated, let previousColors {
            let animation = CABasicAnimation(keyPath: "colors")
            animation.fromValue = previousColors
            animation.toValue = colors
            animation.duration = 0.22
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.tone.add(animation, forKey: "Concept.tone")
        }
    }

    private func preparePhoto(_ image: UIImage?) {
        // A paging placeholder must not erase the previous color field while
        // the next still image is loading.
        guard let image else { return }
        self.photoGeneration &+= 1
        let generation = self.photoGeneration
        self.sourcePhoto = image
        let cacheKey = String(describing: ObjectIdentifier(image)) as NSString
        if let cached = Self.photoCache.object(forKey: cacheKey), cached.source === image {
            self.applyPhoto(cached, animated: self.photo.image != nil && self.window != nil)
            return
        }
        if self.photo.image == nil {
            self.photoContainer.backgroundColor = Self.placeholderColor(image) ?? self.coverColor ?? UIColor(white: 0.25, alpha: 1.0)
        }
        Self.photoQueue.async { [weak self] in
            autoreleasepool {
                guard let input = CIImage(image: image), input.extent.width.isFinite, input.extent.height.isFinite, input.extent.width > 0, input.extent.height > 0 else { return }
                let targetDimension: CGFloat = 256.0
                let scale = min(1.0, targetDimension / max(input.extent.width, input.extent.height))
                let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let blurred = small.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 28.0]).cropped(to: small.extent)
                guard let result = Self.imageContext.createCGImage(blurred, from: small.extent) else { return }
                var rgba = [UInt8](repeating: 0, count: 4)
                let average = small.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: small.extent)])
                rgba.withUnsafeMutableBytes { bytes in
                    Self.imageContext.render(average, toBitmap: bytes.baseAddress!, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                }
                let photoColor = UIColor(red: CGFloat(rgba[0]) / 255.0, green: CGFloat(rgba[1]) / 255.0, blue: CGFloat(rgba[2]) / 255.0, alpha: 1.0)
                let luminance = Self.luminance(photoColor)
                let output = UIImage(cgImage: result)
                let prepared = PreparedPhoto(source: image, image: output, color: photoColor, luminance: luminance)
                DispatchQueue.main.async { [weak self] in
                    Self.photoCache.setObject(prepared, forKey: cacheKey, cost: result.width * result.height * 4)
                    guard let self, self.photoGeneration == generation, self.sourcePhoto === image else { return }
                    self.applyPhoto(prepared, animated: self.window != nil)
                }
            }
        }
    }

    private func applyPhoto(_ prepared: PreparedPhoto, animated: Bool) {
        if self.photo.image == nil {
            self.photo.alpha = animated ? 0.0 : 1.0
        } else if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.22
            self.photo.layer.add(fade, forKey: "Concept.photoChange")
        }
        self.photo.image = prepared.image
        let transition: ContainedViewLayoutTransition = animated ? .animated(duration: 0.22, curve: .easeInOut) : .immediate
        transition.updateAlpha(layer: self.photo.layer, alpha: 1.0)
        self.photoColor = prepared.color
        self.photoLuminance = prepared.luminance
        self.dominantColor = self.expanded || !self.hasCover ? prepared.color : (self.coverColor ?? prepared.color)
        self.updateTone(animated: animated)
    }

    private static func placeholderColor(_ image: UIImage) -> UIColor? {
        guard let source = image.cgImage, source.width <= 512, source.height <= 512 else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return UIColor(red: CGFloat(rgba[0]) / 255.0, green: CGFloat(rgba[1]) / 255.0, blue: CGFloat(rgba[2]) / 255.0, alpha: 1.0)
    }

    func updateScroll(themeFraction: CGFloat) {
        self.themeFade.alpha = themeFraction
    }

}

public func conceptProfileCardTintColor(dominantColor _: UIColor?, isDark: Bool) -> UIColor {
    // The backdrop already supplies its color through the blur. A neutral tint avoids
    // recoloring every card when the larger avatar finishes decoding.
    return isDark ? UIColor.white.withAlphaComponent(0.025) : UIColor.black.withAlphaComponent(0.02)
}

/// Only the profile's own surfaces use this palette. Menus, editing forms,
/// galleries and the application's global theme retain their original palette.
func conceptProfileSurfaceColor(_ theme: PresentationTheme, dominantColor: UIColor? = nil, fraction: CGFloat, decorative: Bool) -> UIColor {
    guard decorative else { return theme.list.itemBlocksBackgroundColor }
    let isDark = theme.overallDarkAppearance
    let tint = conceptProfileCardTintColor(dominantColor: dominantColor, isDark: isDark)
    return tint.mixedWith(theme.list.itemBlocksBackgroundColor, alpha: fraction)
}

func conceptProfileSurfaceTheme(_ theme: PresentationTheme, dominantColor: UIColor? = nil, fraction: CGFloat, decorative: Bool, rows: Bool) -> PresentationTheme {
    let progress = decorative ? fraction : 1.0
    func color(_ overlay: UIColor, _ normal: UIColor) -> UIColor { overlay.mixedWith(normal, alpha: progress) }
    let primary = color(.white, theme.list.itemPrimaryTextColor)
    let secondary = color(UIColor.white.withAlphaComponent(0.65), theme.list.itemSecondaryTextColor)
    let accent = color(.white, theme.list.itemAccentColor)
    let surface = conceptProfileSurfaceColor(theme, dominantColor: dominantColor, fraction: progress, decorative: decorative)
    let list = theme.list.withUpdated(
        blocksBackgroundColor: .clear, plainBackgroundColor: .clear,
        itemPrimaryTextColor: primary, itemSecondaryTextColor: secondary,
        itemAccentColor: accent,
        itemBlocksBackgroundColor: rows ? .clear : surface,
        itemModalBlocksBackgroundColor: surface,
        itemHighlightedBackgroundColor: color(UIColor.white.withAlphaComponent(0.1), theme.list.itemHighlightedBackgroundColor),
        itemBlocksSeparatorColor: color(UIColor.white.withAlphaComponent(0.14), theme.list.itemBlocksSeparatorColor),
        disclosureArrowColor: secondary, sectionHeaderTextColor: secondary,
        freeTextColor: secondary, freeTextSuccessColor: color(.white, theme.list.freeTextSuccessColor)
    )
    let chatList = theme.chatList.withUpdated(
        backgroundColor: .clear, itemBackgroundColor: .clear,
        itemHighlightedBackgroundColor: list.itemHighlightedBackgroundColor,
        titleColor: primary, dateTextColor: secondary, authorNameColor: primary,
        messageTextColor: secondary, messageHighlightedTextColor: primary
    )
    let chat = theme.chat.withUpdated(inputPanel: theme.chat.inputPanel.withUpdated(panelControlColor: primary))
    return PresentationTheme(name: theme.name, index: theme.index, referenceTheme: theme.referenceTheme,
        overallDarkAppearance: (decorative && progress < 0.5) || theme.overallDarkAppearance,
        intro: theme.intro, passcode: theme.passcode, rootController: theme.rootController,
        list: list, chatList: chatList, chat: chat, actionSheet: theme.actionSheet,
        contextMenu: theme.contextMenu, inAppNotification: theme.inAppNotification,
        chart: theme.chart, preview: theme.preview)
}

/// Fade only the final visible bio line beneath More. Unlike painting a solid
/// gradient, a layer mask leaves the material and its live backdrop intact.
final class ConceptProfileTextFadeMask: CALayer {
    private let top = CALayer()
    private let lastLine = CAGradientLayer()

    override init() {
        super.init()
        self.top.backgroundColor = UIColor.white.cgColor
        self.lastLine.startPoint = CGPoint(x: 0.0, y: 0.5)
        self.lastLine.endPoint = CGPoint(x: 1.0, y: 0.5)
        self.lastLine.colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor, UIColor.clear.cgColor]
        self.addSublayer(self.top)
        self.addSublayer(self.lastLine)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(size: CGSize, more: CGRect) {
        let overlapsText = more.minX - 3.0 < size.width
        let lineY = overlapsText ? max(0.0, min(size.height, more.minY - 1.0)) : size.height
        let width = max(1.0, size.width)
        let end = max(0.0, min(1.0, (more.minX - 3.0) / width))
        let start = max(0.0, end - 14.0 / width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.frame = CGRect(origin: .zero, size: size)
        self.top.frame = CGRect(x: 0.0, y: 0.0, width: size.width, height: lineY)
        self.lastLine.frame = CGRect(x: 0.0, y: lineY, width: size.width, height: max(0.0, size.height - lineY))
        self.lastLine.locations = [0.0, NSNumber(value: Double(start)), NSNumber(value: Double(end)), 1.0]
        CATransaction.commit()
    }
}
