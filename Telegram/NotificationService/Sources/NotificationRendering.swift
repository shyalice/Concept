import ConceptNotifications
import SGAppGroupIdentifier // MARK: Swiftgram
import Foundation
import PasscodeCore
import UserNotifications
import SwiftSignalKit
import Postbox
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

let deviceColorSpace: CGColorSpace = {
    if #available(iOSApplicationExtension 9.3, iOS 9.3, *) {
        if let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) {
            return colorSpace
        } else {
            return CGColorSpaceCreateDeviceRGB()
        }
    } else {
        return CGColorSpaceCreateDeviceRGB()
    }
}()

func getSharedDevideGraphicsContextSettings() -> DeviceGraphicsContextSettings {
    struct OpaqueSettings {
        let rowAlignment: Int
        let bitsPerPixel: Int
        let bitsPerComponent: Int
        let opaqueBitmapInfo: CGBitmapInfo
        let colorSpace: CGColorSpace

        init(context: CGContext) {
            self.rowAlignment = context.bytesPerRow
            self.bitsPerPixel = context.bitsPerPixel
            self.bitsPerComponent = context.bitsPerComponent
            self.opaqueBitmapInfo = context.bitmapInfo
            if #available(iOS 10.0, *) {
                if UIScreen.main.traitCollection.displayGamut == .P3 {
                    self.colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? context.colorSpace!
                } else {
                    self.colorSpace = context.colorSpace!
                }
            } else {
                self.colorSpace = context.colorSpace!
            }
            assert(self.rowAlignment == 32)
            assert(self.bitsPerPixel == 32)
            assert(self.bitsPerComponent == 8)
        }
    }

    struct TransparentSettings {
        let transparentBitmapInfo: CGBitmapInfo

        init(context: CGContext) {
            self.transparentBitmapInfo = context.bitmapInfo
        }
    }

    var opaqueSettings: OpaqueSettings?
    var transparentSettings: TransparentSettings?

    if #available(iOS 10.0, *) {
        let opaqueFormat = UIGraphicsImageRendererFormat()
        let transparentFormat = UIGraphicsImageRendererFormat()
        if #available(iOS 12.0, *) {
            opaqueFormat.preferredRange = .standard
            transparentFormat.preferredRange = .standard
        }
        opaqueFormat.opaque = true
        transparentFormat.opaque = false

        let opaqueRenderer = UIGraphicsImageRenderer(bounds: CGRect(origin: CGPoint(), size: CGSize(width: 1.0, height: 1.0)), format: opaqueFormat)
        let _ = opaqueRenderer.image(actions: { context in
            opaqueSettings = OpaqueSettings(context: context.cgContext)
        })

        let transparentRenderer = UIGraphicsImageRenderer(bounds: CGRect(origin: CGPoint(), size: CGSize(width: 1.0, height: 1.0)), format: transparentFormat)
        let _ = transparentRenderer.image(actions: { context in
            transparentSettings = TransparentSettings(context: context.cgContext)
        })
    } else {
        UIGraphicsBeginImageContextWithOptions(CGSize(width: 1.0, height: 1.0), true, 1.0)
        let refContext = UIGraphicsGetCurrentContext()!
        opaqueSettings = OpaqueSettings(context: refContext)
        UIGraphicsEndImageContext()

        UIGraphicsBeginImageContextWithOptions(CGSize(width: 1.0, height: 1.0), false, 1.0)
        let refCtxTransparent = UIGraphicsGetCurrentContext()!
        transparentSettings = TransparentSettings(context: refCtxTransparent)
        UIGraphicsEndImageContext()
    }

    return DeviceGraphicsContextSettings(
        rowAlignment: opaqueSettings!.rowAlignment,
        bitsPerPixel: opaqueSettings!.bitsPerPixel,
        bitsPerComponent: opaqueSettings!.bitsPerComponent,
        opaqueBitmapInfo: opaqueSettings!.opaqueBitmapInfo,
        transparentBitmapInfo: transparentSettings!.transparentBitmapInfo,
        colorSpace: opaqueSettings!.colorSpace
    )
}

public struct DeviceGraphicsContextSettings {
    public static let shared: DeviceGraphicsContextSettings = getSharedDevideGraphicsContextSettings()

    public let rowAlignment: Int
    public let bitsPerPixel: Int
    public let bitsPerComponent: Int
    public let opaqueBitmapInfo: CGBitmapInfo
    public let transparentBitmapInfo: CGBitmapInfo
    public let colorSpace: CGColorSpace

    public func bytesPerRow(forWidth width: Int) -> Int {
        let baseValue = self.bitsPerPixel * width / 8
        return (baseValue + 31) & ~0x1F
    }
}

final class DrawingContext {
    let size: CGSize
    let scale: CGFloat
    let scaledSize: CGSize
    let bytesPerRow: Int
    private let bitmapInfo: CGBitmapInfo
    let length: Int
    let bytes: UnsafeMutableRawPointer
    private let data: Data
    private let context: CGContext

    private var hasGeneratedImage = false

    func withContext(_ f: (CGContext) -> ()) {
        let context = self.context

        context.translateBy(x: self.size.width / 2.0, y: self.size.height / 2.0)
        context.scaleBy(x: 1.0, y: -1.0)
        context.translateBy(x: -self.size.width / 2.0, y: -self.size.height / 2.0)

        f(context)

        context.translateBy(x: self.size.width / 2.0, y: self.size.height / 2.0)
        context.scaleBy(x: 1.0, y: -1.0)
        context.translateBy(x: -self.size.width / 2.0, y: -self.size.height / 2.0)
    }

    func withFlippedContext(_ f: (CGContext) -> ()) {
        f(self.context)
    }

    init(size: CGSize, scale: CGFloat = 1.0, opaque: Bool = false, clear: Bool = false) {
        assert(!size.width.isZero && !size.height.isZero)
        let size: CGSize = CGSize(width: max(1.0, size.width), height: max(1.0, size.height))

        let actualScale: CGFloat
        if scale.isZero {
            actualScale = 1.0
        } else {
            actualScale = scale
        }
        self.size = size
        self.scale = actualScale
        self.scaledSize = CGSize(width: size.width * actualScale, height: size.height * actualScale)

        self.bytesPerRow = DeviceGraphicsContextSettings.shared.bytesPerRow(forWidth: Int(self.scaledSize.width))

        self.length = self.bytesPerRow * Int(self.scaledSize.height)

        self.bytes = malloc(self.length)
        self.data = Data(bytesNoCopy: self.bytes, count: self.length, deallocator: .custom({ bytes, _ in
            free(bytes)
        }))

        if opaque {
            self.bitmapInfo = DeviceGraphicsContextSettings.shared.opaqueBitmapInfo
        } else {
            self.bitmapInfo = DeviceGraphicsContextSettings.shared.transparentBitmapInfo
        }

        self.context = CGContext(
            data: self.bytes,
            width: Int(self.scaledSize.width),
            height: Int(self.scaledSize.height),
            bitsPerComponent: 8,
            bytesPerRow: self.bytesPerRow,
            space: deviceColorSpace,
            bitmapInfo: self.bitmapInfo.rawValue,
            releaseCallback: nil,
            releaseInfo: nil
        )!
        self.context.scaleBy(x: self.scale, y: self.scale)

        if clear {
            memset(self.bytes, 0, self.length)
        }
    }

    func generateImage() -> UIImage? {
        if self.scaledSize.width.isZero || self.scaledSize.height.isZero {
            return nil
        }
        if self.hasGeneratedImage {
            preconditionFailure()
        }
        self.hasGeneratedImage = true

        guard let dataProvider = CGDataProvider(data: self.data as CFData) else {
            return nil
        }

        if let image = CGImage(
            width: Int(self.scaledSize.width),
            height: Int(self.scaledSize.height),
            bitsPerComponent: self.context.bitsPerComponent,
            bitsPerPixel: self.context.bitsPerPixel,
            bytesPerRow: self.context.bytesPerRow,
            space: DeviceGraphicsContextSettings.shared.colorSpace,
            bitmapInfo: self.context.bitmapInfo,
            provider: dataProvider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) {
            return UIImage(cgImage: image, scale: self.scale, orientation: .up)
        } else {
            return nil
        }
    }
}

private extension CGSize {
    func fitted(_ size: CGSize) -> CGSize {
        var fittedSize = self
        if fittedSize.width > size.width {
            fittedSize = CGSize(width: size.width, height: floor((fittedSize.height * size.width / max(fittedSize.width, 1.0))))
        }
        if fittedSize.height > size.height {
            fittedSize = CGSize(width: floor((fittedSize.width * size.height / max(fittedSize.height, 1.0))), height: size.height)
        }
        return fittedSize
    }
}

func convertLottieImage(data: Data, size: CGSize, forceSquare: Bool) -> UIImage? {
    let decompressedData = TGGUnzipData(data, 512 * 1024) ?? data
    guard let animation = makeLottieInstance(data: decompressedData, fitzModifier: .none, colorReplacements: nil) else {
        return nil
    }
    let actualSize: CGSize
    if forceSquare {
        actualSize = animation.dimensions.fitted(size)
    } else {
        actualSize = size
    }
    let context = DrawingContext(size: actualSize, scale: 1.0, opaque: false, clear: true)
    animation.renderFrame(with: 0, into: context.bytes.assumingMemoryBound(to: UInt8.self), width: Int32(context.scaledSize.width), height: Int32(context.scaledSize.height), bytesPerRow: Int32(context.bytesPerRow))
    return context.generateImage()
}

func testAvatarImage(size: CGSize) -> UIImage? {
    UIGraphicsBeginImageContextWithOptions(size, false, 2.0)
    let context = UIGraphicsGetCurrentContext()!

    context.beginPath()
    context.addEllipse(in: CGRect(x: 0.0, y: 0.0, width: size.width, height: size.height))
    context.clip()

    context.setFillColor(UIColor.red.cgColor)
    context.fill(CGRect(origin: CGPoint(), size: size))

    let image = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return image
}

func avatarRoundImage(size: CGSize, source: UIImage, isStory: Bool) -> UIImage? {
    UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
    let context = UIGraphicsGetCurrentContext()

    if isStory {
        let lineWidth: CGFloat = 2.0
        context?.beginPath()
        context?.addEllipse(in: CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: size.width, height: size.height)).insetBy(dx: lineWidth * 0.5, dy: lineWidth * 0.5))
        context?.clip()
        
        let colors: [CGColor] = [
            UIColor(rgb: 0x34C76F).cgColor,
            UIColor(rgb: 0x3DA1FD).cgColor
        ]
        var locations: [CGFloat] = [0.0, 1.0]
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: &locations)!
        
        context?.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: size.height), options: CGGradientDrawingOptions())
        
        context?.setBlendMode(.copy)
        context?.fillEllipse(in: CGRect(origin: CGPoint(), size: size).insetBy(dx: 2.0, dy: 2.0))
        
        context?.setBlendMode(.normal)
        context?.beginPath()
        context?.addEllipse(in: CGRect(x: 0.0, y: 0.0, width: size.width, height: size.height).insetBy(dx: 4.0, dy: 4.0))
        context?.clip()
        
        source.draw(in: CGRect(origin: CGPoint(), size: size).insetBy(dx: 4.0, dy: 4.0))
    } else {
        context?.beginPath()
        context?.addEllipse(in: CGRect(x: 0.0, y: 0.0, width: size.width, height: size.height))
        context?.clip()
        
        source.draw(in: CGRect(origin: CGPoint(), size: size))
    }

    let image = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return image
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255.0, green: CGFloat((rgb >> 8) & 0xff) / 255.0, blue: CGFloat(rgb & 0xff) / 255.0, alpha: 1.0)
    }
}

let gradientColors: [NSArray] = [
    [UIColor(rgb: 0xff516a).cgColor, UIColor(rgb: 0xff885e).cgColor],
    [UIColor(rgb: 0xffa85c).cgColor, UIColor(rgb: 0xffcd6a).cgColor],
    [UIColor(rgb: 0x665fff).cgColor, UIColor(rgb: 0x82b1ff).cgColor],
    [UIColor(rgb: 0x54cb68).cgColor, UIColor(rgb: 0xa0de7e).cgColor],
    [UIColor(rgb: 0x4acccd).cgColor, UIColor(rgb: 0x00fcfd).cgColor],
    [UIColor(rgb: 0x2a9ef1).cgColor, UIColor(rgb: 0x72d5fd).cgColor],
    [UIColor(rgb: 0xd669ed).cgColor, UIColor(rgb: 0xe0a2f3).cgColor],
]

func avatarViewLettersImage(size: CGSize, peerId: PeerId, letters: [String], isStory: Bool) -> UIImage? {
    UIGraphicsBeginImageContextWithOptions(size, false, 2.0)
    let context = UIGraphicsGetCurrentContext()

    context?.beginPath()
    if isStory {
        context?.addEllipse(in: CGRect(x: 0.0, y: 0.0, width: size.width, height: size.height).insetBy(dx: 4.0, dy: 4.0))
    } else {
        context?.addEllipse(in: CGRect(x: 0.0, y: 0.0, width: size.width, height: size.height))
    }
    context?.clip()

    let colorIndex: Int
    if peerId.namespace == .max {
        colorIndex = 0
    } else {
        colorIndex = abs(Int(clamping: peerId.id._internalGetInt64Value()))
    }

    let colorsArray = gradientColors[colorIndex % gradientColors.count]
    var locations: [CGFloat] = [1.0, 0.0]
    let gradient = CGGradient(colorsSpace: deviceColorSpace, colors: colorsArray, locations: &locations)!

    context?.drawLinearGradient(gradient, start: CGPoint(), end: CGPoint(x: 0.0, y: size.height), options: CGGradientDrawingOptions())

    context?.setBlendMode(.normal)

    let string = letters.count == 0 ? "" : (letters[0] + (letters.count == 1 ? "" : letters[1]))
    let attributedString = NSAttributedString(string: string, attributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 20.0), NSAttributedString.Key.foregroundColor: UIColor.white])

    let line = CTLineCreateWithAttributedString(attributedString)
    let lineBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

    let lineOffset = CGPoint(x: string == "B" ? 1.0 : 0.0, y: 0.0)
    let lineOrigin = CGPoint(x: floor(-lineBounds.origin.x + (size.width - lineBounds.size.width) / 2.0) + lineOffset.x, y: floor(-lineBounds.origin.y + (size.height - lineBounds.size.height) / 2.0))

    context?.translateBy(x: size.width / 2.0, y: size.height / 2.0)
    context?.scaleBy(x: 1.0, y: -1.0)
    context?.translateBy(x: -size.width / 2.0, y: -size.height / 2.0)

    context?.translateBy(x: lineOrigin.x, y: lineOrigin.y)
    if let context = context {
        CTLineDraw(line, context)
    }
    context?.translateBy(x: -lineOrigin.x, y: -lineOrigin.y)
    
    if isStory {
        context?.resetClip()
        
        let lineWidth: CGFloat = 2.0
        context?.setLineWidth(lineWidth)
        context?.addEllipse(in: CGRect(origin: CGPoint(x: size.width * 0.5, y: size.height * 0.5), size: CGSize(width: size.width, height: size.height)).insetBy(dx: lineWidth * 0.5, dy: lineWidth * 0.5))
        context?.replacePathWithStrokedPath()
        context?.clip()
        
        let colors: [CGColor] = [
            UIColor(rgb: 0x34C76F).cgColor,
            UIColor(rgb: 0x3DA1FD).cgColor
        ]
        var locations: [CGFloat] = [0.0, 1.0]
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: &locations)!
        
        context?.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: size.height), options: CGGradientDrawingOptions())
    }

    let image = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return image
}

func avatarImage(path: String?, peerId: PeerId, letters: [String], size: CGSize, isStory: Bool) -> UIImage {
    if let path = path, let image = UIImage(contentsOfFile: path), let roundImage = avatarRoundImage(size: size, source: image, isStory: isStory) {
        return roundImage
    } else {
        return avatarViewLettersImage(size: size, peerId: peerId, letters: letters, isStory: isStory)!
    }
}

func storeTemporaryImage(path: String, fileExtension: String) -> String {
    let imagesPath = NSTemporaryDirectory() + "/aps-data"
    let _ = try? FileManager.default.createDirectory(at: URL(fileURLWithPath: imagesPath), withIntermediateDirectories: true, attributes: nil)

    let tempPath = imagesPath + "\(path.persistentHashValue).\(fileExtension)"
    if FileManager.default.fileExists(atPath: tempPath) {
        return tempPath
    }

    let _ = try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: URL(fileURLWithPath: tempPath))

    return tempPath
}

@available(iOS 15.0, *)
func peerAvatar(mediaBox: MediaBox, accountPeerId: PeerId, peer: Peer, isStory: Bool) -> INImage? {
    if let resource = smallestImageRepresentation(peer.profileImageRepresentations)?.resource, let path = mediaBox.completedResourcePath(resource) {
        let cachedPath = mediaBox.cachedRepresentationPathForId(resource.id.stringRepresentation, representationId: "intents\(isStory ? "-story2" : "").png", keepDuration: .shortLived)
        if let _ = fileSize(cachedPath), !"".isEmpty {
            return INImage(url: URL(fileURLWithPath: storeTemporaryImage(path: cachedPath, fileExtension: "jpg")))
        } else {
            let image = avatarImage(path: path, peerId: peer.id, letters: peer.displayLetters, size: CGSize(width: 50.0, height: 50.0), isStory: isStory)
            if let data = image.pngData() {
                let _ = try? FileManager.default.removeItem(atPath: cachedPath)
                let _ = try? data.write(to: URL(fileURLWithPath: cachedPath), options: .atomic)
            }

            return INImage(url: URL(fileURLWithPath: storeTemporaryImage(path: cachedPath, fileExtension: "jpg")))
        }
    }

    let cachedPath = mediaBox.cachedRepresentationPathForId("lettersAvatar2-\(peer.displayLetters.joined(separator: ","))\(isStory ? "-story" : "")", representationId: "intents.png", keepDuration: .shortLived)
    if let _ = fileSize(cachedPath) {
        return INImage(url: URL(fileURLWithPath: storeTemporaryImage(path: cachedPath, fileExtension: "jpg")))
    } else {
        let image = avatarImage(path: nil, peerId: peer.id, letters: peer.displayLetters, size: CGSize(width: 50.0, height: 50.0), isStory: isStory)
        if let data = image.pngData() {
            let _ = try? data.write(to: URL(fileURLWithPath: cachedPath), options: .atomic)
        }
        return INImage(url: URL(fileURLWithPath: storeTemporaryImage(path: cachedPath, fileExtension: "jpg")))
    }
}

@available(iOSApplicationExtension 10.0, iOS 10.0, *)
struct NotificationContent: CustomStringConvertible {
    struct CustomEmoji {
        var range: Range<Int>
        var fileId: Int64
        
        init(range: Range<Int>, fileId: Int64) {
            self.range = range
            self.fileId = fileId
        }
    }
    
    var title: String?
    var subtitle: String?
    var body: String?
    var customEmoji: [CustomEmoji] = []
    var resolvedEmojiFiles: [Int64: String] = [:]
    var threadId: String?
    var sound: String?
    var badge: Int?
    var category: String?
    var userInfo: [AnyHashable: Any] = [:]
    var attachments: [UNNotificationAttachment] = []
    var silent = false
    /// The account this notification was delivered to, set only while more than one is signed
    /// in (see `notificationRecipientAccountName`).
    var recipientAccountName: String?
    // MARK: Swiftgram
    var isEmpty: Bool
    var isMentionOrReply: Bool
    var isPinned: Bool = false
    let chatId: Int64?
    let sgStatus: SGStatus
    //

    struct Sender {
        var peerId: PeerId
        /// Without the recipient account or the muted marker, which `NotificationNames` adds.
        var name: String
        var contactIdentifier: String?
    }

    var sender: Sender?
    var senderImage: INImage?
    
    var isLockedMessage: String?
    
    init(sgStatus: SGStatus, isLockedMessage: String?, isEmpty: Bool = false, isMentionOrReply: Bool = false, chatId: Int64? = nil) { // MARK: Swiftgram
        self.sgStatus = sgStatus // MARK: Swiftgram
        self.isLockedMessage = isLockedMessage
        self.isEmpty = isEmpty // MARK: Swiftgram
        self.isMentionOrReply = isMentionOrReply // MARK: Swiftgram
        self.chatId = chatId // MARK: Swiftgram
    }

    var description: String {
        var string = "{"
        string += " title: \(String(describing: self.title))\n"
        string += " subtitle: \(String(describing: self.subtitle))\n"
        string += " body: \(String(describing: self.body)),\n"
        string += " threadId: \(String(describing: self.threadId)),\n"
        string += " sound: \(String(describing: self.sound)),\n"
        string += " badge: \(String(describing: self.badge)),\n"
        string += " category: \(String(describing: self.category)),\n"
        string += " userInfo: \(String(describing: self.userInfo)),\n"
        string += " senderImage: \(self.senderImage != nil ? "non-empty" : "empty"),\n"
        string += " isLockedMessage: \(String(describing: self.isLockedMessage)),\n"
        string += " attachments: \(self.attachments),\n"
        string += " resolvedEmojiFiles: \(self.resolvedEmojiFiles.count) files,\n"
        // MARK: Swiftgram
        string += " isEmpty: \(self.isEmpty),\n"
        string += " chatId: \(String(describing: self.chatId)),\n"
        string += " isMentionOrReply: \(self.isMentionOrReply),\n"
        string += " isPinned: \(self.isPinned),\n"
        string += " forceIsEmpty: \(self.forceIsEmpty),\n"
        string += " forceIsSilent: \(self.forceIsSilent),\n"
        string += " sgStatus: \(self.sgStatus.status),\n"
        //
        string += "}"
        return string
    }

    mutating func addSenderInfo(mediaBox: MediaBox, accountPeerId: PeerId, peer: Peer, topicTitle: String?, contactIdentifier: String?, isStory: Bool) {
        if #available(iOS 15.0, *) {
            let image = peerAvatar(mediaBox: mediaBox, accountPeerId: accountPeerId, peer: peer, isStory: isStory)

            self.senderImage = image

            var name: String = peer.debugDisplayTitle
            if let topicTitle {
                name = "\(topicTitle) (\(name))"
            }
            self.sender = Sender(peerId: peer.id, name: name, contactIdentifier: contactIdentifier)
        }
    }

    @available(iOS 15.0, *)
    private func incomingMessageIntent(sender: Sender, senderName: String, groupName: String?, conversationId: String, body: String) -> INSendMessageIntent {
        var personNameComponents = PersonNameComponents()
        personNameComponents.nickname = senderName

        let senderPerson = INPerson(
            personHandle: INPersonHandle(value: "\(sender.peerId.toInt64())", type: .unknown),
            nameComponents: personNameComponents,
            displayName: senderName,
            image: self.senderImage,
            contactIdentifier: sender.contactIdentifier,
            customIdentifier: "\(sender.peerId.toInt64())",
            isMe: false,
            suggestionType: .none
        )
        let mePerson = INPerson(
            personHandle: INPersonHandle(value: "0", type: .unknown),
            nameComponents: nil,
            displayName: nil,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: nil,
            isMe: true,
            suggestionType: .none
        )

        let recipients: [INPerson]
        let speakableGroup: INSpeakableString?
        if let groupName = groupName, !groupName.isEmpty {
            speakableGroup = INSpeakableString(spokenPhrase: groupName)
            recipients = [senderPerson, mePerson]
        } else {
            speakableGroup = nil
            recipients = [mePerson]
        }

        let intent = INSendMessageIntent(
            recipients: recipients,
            outgoingMessageType: .outgoingMessageText,
            content: body,
            speakableGroupName: speakableGroup,
            conversationIdentifier: conversationId,
            serviceName: nil,
            sender: senderPerson,
            attachments: nil
        )
        if let senderImage = self.senderImage {
            intent.setImage(senderImage, forParameterNamed: \.sender)
        }
        return intent
    }

    func donateInteraction() {
        guard #available(iOS 15.0, *), self.isLockedMessage == nil, !self.isEmpty, !self.forceIsEmpty,
              let sender = self.sender else { return }
        let names = NotificationNames(title: self.title, senderName: sender.name, silent: self.silent || self.forceIsSilent, recipientAccountName: self.recipientAccountName)
        guard let donatedSenderName = names.donatedSenderName else { return }

        let isGroupChat: Bool
        if self.chatId != nil || self.category?.hasPrefix("g") == true {
            isGroupChat = true
        } else if let title = self.title, !title.isEmpty, title != sender.name {
            isGroupChat = true
        } else {
            isGroupChat = false
        }

        let donatedGroupName = isGroupChat ? self.title : nil
        let conversationId = isGroupChat ? (self.chatId.map { "\($0)" } ?? self.title ?? "\(sender.peerId.toInt64())") : "\(sender.peerId.toInt64())"

        let intent = self.incomingMessageIntent(sender: sender, senderName: donatedSenderName, groupName: donatedGroupName, conversationId: conversationId, body: self.body ?? "")
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
    }

    func generate() -> UNNotificationContent {
        var content = UNMutableNotificationContent()
        
        // MARK: Swiftgram
        #if DEBUG
        #endif
        if (self.isEmpty || self.forceIsEmpty) && !sgLegacyNotificationsFix {
            return UNNotificationContent()
        }
        //

        let names = NotificationNames(title: self.title, senderName: self.sender?.name, silent: self.silent || self.forceIsSilent, recipientAccountName: self.recipientAccountName) // MARK: Swiftgram

        if let title = names.title {
            content.title = title
        }
        
        if let subtitle = self.subtitle {
            content.subtitle = subtitle
        }
        if let body = self.body {
            if #available(iOS 18.0, *) {
                // Not while locked: the locked message below replaces only `body`, and an `attributedBody` set
                // here would still show the message's text.
                if self.isLockedMessage == nil, !self.resolvedEmojiFiles.isEmpty {
                    let attributedString = NSMutableAttributedString(string: body)
                    
                    let sortedEmoji = self.customEmoji.sorted(by: { $0.range.lowerBound < $1.range.lowerBound })
                    
                    // An emoji repeated in the body is decoded once.
                    var images: [Int64: UIImage] = [:]
                    for emoji in sortedEmoji.reversed() {
                        if emoji.range.lowerBound < 0 || emoji.range.upperBound > attributedString.length {
                            continue
                        }
                        let image: UIImage
                        if let cachedImage = images[emoji.fileId] {
                            image = cachedImage
                        } else {
                            guard let filePath = self.resolvedEmojiFiles[emoji.fileId] else {
                                continue
                            }
                            guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
                                continue
                            }
                            if let lottieImage = convertLottieImage(data: fileData, size: CGSize(width: 40.0, height: 40.0), forceSquare: false) {
                                image = lottieImage
                            } else if let webpImage = WebP.convert(fromWebP: fileData) {
                                image = webpImage
                            } else {
                                continue
                            }
                            images[emoji.fileId] = image
                        }
                        
                        let emojiRange = NSRange(location: emoji.range.lowerBound, length: emoji.range.upperBound - emoji.range.lowerBound)
                        let substring = attributedString.attributedSubstring(from: emojiRange)
                        
                        guard let glyph = try? Customoji.makeGlyph(from: image, description: substring.string, tileSizes: [40], cropToSquare: false) else {
                            continue
                        }
                        let imageString = NSAttributedString(adaptiveImageGlyph: glyph, attributes: [:])
                        attributedString.replaceCharacters(in: emojiRange, with: "")
                        attributedString.insert(imageString, at: emojiRange.lowerBound)
                    }
                    content.setValue(attributedString, forKey: "attributedBody")
                } else {
                    content.body = body
                }
            } else {
                content.body = body
            }
        }
        
        if !content.title.isEmpty || !content.subtitle.isEmpty || !content.body.isEmpty {
            if let isLockedMessage = self.isLockedMessage {
                content.body = isLockedMessage
            }
        }
        
        if let threadId = self.threadId {
            content.threadIdentifier = threadId
        }
        if let sound = self.sound {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: sound))
        }
        if let badge = self.badge {
            content.badge = badge as NSNumber
        }
        if let category = self.category {
            content.categoryIdentifier = category
        }
        if !self.userInfo.isEmpty {
            content.userInfo = self.userInfo
        }
        if self.isLockedMessage == nil {
            if !self.attachments.isEmpty {
                content.attachments = self.attachments
            }
        }

        if #available(iOS 15.0, *) {
            if self.isLockedMessage == nil, !self.isEmpty, !self.forceIsEmpty, let sender = self.sender, let donatedSenderName = names.donatedSenderName, let displayedSenderName = names.displayedSenderName {
                let isGroupChat: Bool
                if self.chatId != nil || self.category?.hasPrefix("g") == true {
                    isGroupChat = true
                } else if let title = self.title, !title.isEmpty, title != sender.name {
                    isGroupChat = true
                } else {
                    isGroupChat = false
                }

                let donatedGroupName = isGroupChat ? self.title : nil
                let displayedGroupName = isGroupChat ? names.title : nil
                let conversationId = isGroupChat ? (self.chatId.map { "\($0)" } ?? self.title ?? "\(sender.peerId.toInt64())") : "\(sender.peerId.toInt64())"

                let donatedIntent = self.incomingMessageIntent(sender: sender, senderName: donatedSenderName, groupName: donatedGroupName, conversationId: conversationId, body: content.body)

                let displayedIntent: INSendMessageIntent
                if displayedSenderName == donatedSenderName && displayedGroupName == donatedGroupName {
                    displayedIntent = donatedIntent
                } else {
                    displayedIntent = self.incomingMessageIntent(sender: sender, senderName: displayedSenderName, groupName: displayedGroupName, conversationId: conversationId, body: content.body)
                }

                do {
                    if let updated = try content.updating(from: displayedIntent) as? UNMutableNotificationContent {
                        content = updated
                    }
                } catch let e {
                    print("Exception: \(e)")
                }

                // If it is a group chat, ensure that content.title remains the chat title!
                if isGroupChat, let title = names.title, !title.isEmpty {
                    content.title = title
                    if content.subtitle.isEmpty {
                        content.subtitle = displayedSenderName
                    }
                }
            }
        }
        
        // MARK: Swiftgram
        if (self.isEmpty || self.forceIsEmpty) && sgLegacyNotificationsFix {
            // Use a new object so communication-intent metadata and rich text
            // cannot survive suppression. Keep only the badge correction.
            let placeholder = UNMutableNotificationContent()
            placeholder.title = " "
            placeholder.badge = content.badge
            placeholder.threadIdentifier = "empty-notification"
            if #available(iOSApplicationExtension 15.0, iOS 15.0, *) {
                placeholder.interruptionLevel = .passive
                placeholder.relevanceScore = 0.0
            }
            return placeholder
        }
        
        if self.forceIsSilent {
            content.sound = nil
        }
        //
        return content
    }
}

// MARK: Swiftgram
extension NotificationContent {
    private var notificationPolicy: NotificationPresentationPolicy {
        return NotificationPresentationPolicy(enabled: self.sgStatus.status > 1,
            isPinned: self.isPinned, isMentionOrReply: self.isMentionOrReply,
            chatId: self.chatId.map(String.init), pinnedAction: sgPinnedMessageAction,
            pinnedExceptions: sgPinnedMessageActionExceptions,
            mentionAction: sgMentionAndReplyAction, mentionExceptions: sgMentionAndReplyActionExceptions)
    }
    var forceIsEmpty: Bool { return !self.isEmpty && self.notificationPolicy.suppress }
    var forceIsSilent: Bool { return !self.silent && self.notificationPolicy.silence }
}
//
