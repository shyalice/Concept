import Foundation
import UIKit
import UserNotifications
import Intents
import CoreText
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import TelegramStringFormatting
import AccountContext
import AppLockState
import ConceptNotifications
import LocalizedPeerData
import PlatformRestrictionMatching

private final class ConceptLocalNotificationDeliveryState {
    var isCancelled = false
    var releaseClaim: (() -> Void)?
}

func deliverConceptLocalNotifications(messages: [EngineMessage], account: AccountContext, sharedContext: SharedApplicationContext, settings: InAppNotificationSettings) -> Signal<Void, NoError> {
    return Signal { subscriber in
        let work = DisposableSet()
        let state = ConceptLocalNotificationDeliveryState()
        let accountId = account.account.id
        let basePath = sharedContext.sharedContext.basePath

        work.add((sharedContext.sharedContext.accountManager.sharedData(keys: [SharedDataKeys.conceptSecretPasscodes])
        |> take(1)
        |> deliverOnMainQueue).start(next: { data in
            guard BackgroundNotificationSettings.isEnabled, UIApplication.shared.applicationState != .active else {
                subscriber.putCompletion()
                return
            }
            let secrets = (data.entries[SharedDataKeys.conceptSecretPasscodes]?.get(ConceptSecretPasscodes.self) ?? .defaultSettings).withCheckedTimeoutUsingLockStateFile(rootPath: basePath)
            guard !secrets.inactiveAccountIds().contains(accountId) else {
                subscriber.putCompletion()
                return
            }

            let locked: Bool
            if let raw = try? Data(contentsOf: URL(fileURLWithPath: appLockStatePath(rootPath: basePath))), let state = try? JSONDecoder().decode(LockState.self, from: raw) {
                locked = isAppLocked(state: state)
            } else {
                // No lock-state file means the app never asked to be locked. Treating the
                // absent file as "locked" hid every preview behind "Message".
                locked = false
            }

            let hiddenPeers = secrets.inactiveSecretChatPeerIds(accountId: accountId)
            var seen = Set<EngineMessage.Id>()
            var items: [EngineMessage] = []
            for message in messages {
                guard message.flags.contains(.Incoming), !message.flags.contains(.WasScheduled), !hiddenPeers.contains(message.id.peerId) else {
                    continue
                }
                if seen.insert(message.id).inserted {
                    items.append(message)
                }
            }
            guard !items.isEmpty else {
                subscriber.putCompletion()
                return
            }

            postNextConceptLocalNotification(items: items, index: 0, account: account, settings: settings, locked: locked, work: work, state: state, completion: subscriber.putCompletion)
        }))

        return ActionDisposable {
            Queue.mainQueue().async {
                state.isCancelled = true
                state.releaseClaim?()
                state.releaseClaim = nil
                work.dispose()
            }
        }
    }

}

private func postNextConceptLocalNotification(items: [EngineMessage], index: Int, account: AccountContext, settings: InAppNotificationSettings, locked: Bool, work: DisposableSet, state: ConceptLocalNotificationDeliveryState, completion: @escaping () -> Void) {
    guard !state.isCancelled, BackgroundNotificationSettings.isEnabled, UIApplication.shared.applicationState != .active, index < items.count else {
        completion()
        return
    }
    let message = items[index]
    let id = message.id
    let claim = UUID().uuidString
    var completed = false
    let finish = {
        guard !completed else {
            return
        }
        completed = true
        state.releaseClaim = nil
        postNextConceptLocalNotification(items: items, index: index + 1, account: account, settings: settings, locked: locked, work: work, state: state, completion: completion)
    }

    let disposable = (account.engine.messages.claimBackgroundNotification(id: id, token: claim)
    |> deliverOnMainQueue
    |> take(1)).start(next: { (candidate: EngineBackgroundNotificationCandidate?) in
        guard let candidate else {
            finish()
            return
        }
        state.releaseClaim = {
            let _ = account.engine.messages.releaseBackgroundNotificationClaim(id: id, token: claim).startStandalone()
        }
        var avatarPeers: [EnginePeer] = []
        if let peer = candidate.message.peers[id.peerId].flatMap(EnginePeer.init) {
            avatarPeers.append(peer)
        }
        if let author = candidate.message.author, !avatarPeers.contains(where: { $0.id == author.id }) {
            avatarPeers.append(author)
        }
        let preparations: [Signal<Bool, NoError>] = avatarPeers.map { peer in
            return Signal { subscriber in
                account.engine.prepareConceptNotificationAvatar(peer: peer).start(completed: {
                    subscriber.putNext(true)
                    subscriber.putCompletion()
                })
            }
        }
        let preparation: Signal<Bool, NoError> = preparations.isEmpty ? .single(true) : (combineLatest(preparations) |> map { _ in true })
        work.add((preparation
        |> timeout(2.0, queue: .mainQueue(), alternate: .single(false))
        |> take(1)
        |> deliverOnMainQueue).start(next: { _ in
            guard !state.isCancelled, BackgroundNotificationSettings.isEnabled, UIApplication.shared.applicationState != .active else {
                let _ = account.engine.messages.releaseBackgroundNotificationClaim(id: id, token: claim).startStandalone()
                finish()
                return
            }
            guard let notification = conceptLocalNotificationContent(candidate: candidate, account: account, settings: settings, locked: locked) else {
                let _ = account.engine.messages.releaseBackgroundNotificationClaim(id: id, token: claim).startStandalone()
                finish()
                return
            }
            let request = UNNotificationRequest(identifier: notification.identifier, content: notification.content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                Queue.mainQueue().async {
                    if error == nil && BackgroundNotificationSettings.isEnabled && !state.isCancelled {
                        let _ = account.engine.messages.commitBackgroundNotificationClaim(id: id, token: claim).startStandalone()
                    } else {
                        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notification.identifier])
                        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notification.identifier])
                        let _ = account.engine.messages.releaseBackgroundNotificationClaim(id: id, token: claim).startStandalone()
                    }
                    finish()
                }
            }
        }))
    }, completed: {})
    work.add(disposable)
}

struct ConceptLocalNotificationRequest {
    let identifier: String
    let content: UNNotificationContent
}

func conceptLocalNotificationContent(candidate: EngineBackgroundNotificationCandidate, account: AccountContext, settings: InAppNotificationSettings, locked: Bool) -> ConceptLocalNotificationRequest? {
    let message = candidate.message
    let id = message.id
    let secrets = account.sharedContext.currentConceptSecretPasscodes.with { $0 }
        .withCheckedTimeoutUsingLockStateFile(rootPath: account.sharedContext.basePath)
    guard !secrets.inactiveAccountIds().contains(account.account.id),
          !secrets.inactiveSecretChatPeerIds(accountId: account.account.id).contains(id.peerId) else { return nil }
    let presentationData = account.sharedContext.currentPresentationData.with { $0 }
    let strings = presentationData.strings
    let contentSettings = account.currentContentSettings.with { $0 }

    guard let peer = message.peers[id.peerId].flatMap(EnginePeer.init) else {
        return nil
    }
    var displayPeer = peer
    if let secretChat = message.peers[id.peerId] as? TelegramSecretChat, let associatedPeerId = secretChat.associatedPeerId, let associatedPeer = message.peers[associatedPeerId].flatMap(EnginePeer.init) {
        displayPeer = associatedPeer
    }
    if message._asMessage().restrictionReason(platform: "ios", contentSettings: contentSettings) != nil {
        return nil
    }
    if peer.restrictionText(platform: "ios", contentSettings: contentSettings) != nil {
        return nil
    }

    let isChannel: Bool
    if let channel = message.peers[id.peerId] as? TelegramChannel, case .broadcast = channel.info {
        isChannel = true
    } else {
        isChannel = false
    }
    let isGroup: Bool
    if message.peers[id.peerId] is TelegramGroup {
        isGroup = true
    } else if let channel = message.peers[id.peerId] as? TelegramChannel, case .group = channel.info {
        isGroup = true
    } else {
        isGroup = false
    }

    let chatName = conceptNotificationPeerName(displayPeer, strings: strings, nameDisplayOrder: presentationData.nameDisplayOrder)
    let authorPeer = message.author
    let authorName = authorPeer.map { conceptNotificationPeerName($0, strings: strings, nameDisplayOrder: presentationData.nameDisplayOrder) }

    let conversationName: String
    if isGroup, let topicTitle = candidate.topicTitle, !topicTitle.isEmpty {
        conversationName = "\(chatName) · \(topicTitle)"
    } else {
        conversationName = chatName
    }
    var title = conversationName.isEmpty ? "Concept" : conversationName
    if isChannel || isGroup {
        title = conversationName.isEmpty ? (authorName ?? "Concept") : conversationName
    }

    var body: String
    let lockPath = appLockStatePath(rootPath: account.sharedContext.basePath)
    let currentLock = (try? Data(contentsOf: URL(fileURLWithPath: lockPath))).flatMap { try? JSONDecoder().decode(LockState.self, from: $0) }
    let locked = locked || currentLock.map(isAppLocked(state:)) == true
    let showContents = candidate.displayContents && settings.displayPreviews && !locked && !message._asMessage().containsSecretMedia
    if showContents {
        let (attributedText, _, _) = descriptionStringForMessage(contentSettings: contentSettings, message: message, strings: strings, nameDisplayOrder: presentationData.nameDisplayOrder, dateTimeFormat: presentationData.dateTimeFormat, accountPeerId: account.account.peerId)
        var text = foldLineBreaks(attributedText.string).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = strings.Watch_MessageView_Title
        }
        if text.count > 500 {
            text = String(text.prefix(500))
        }
        body = text
    } else {
        body = locked ? strings.PUSH_LOCKED_MESSAGE("").string : strings.Watch_MessageView_Title
        if !settings.displayNameOnLockscreen {
            title = "Concept"
        }
    }

    var content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.categoryIdentifier = locked ? "unknown" : (isChannel ? "c" : (isGroup ? "gr" : "r"))
    content.threadIdentifier = "\(account.account.id.int64)_\(id.peerId.toInt64())"
    if let threadId = message.threadId {
        content.threadIdentifier += "_\(threadId)"
    }
    if candidate.sound != .none {
        if let customSound = settings.customSound, !customSound.isEmpty {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: customSound))
        } else {
            switch candidate.sound {
            case let .bundledModern(id):
                content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "\(id + 100).m4a"))
            case let .bundledClassic(id):
                content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "\(id + 2).m4a"))
            default:
                content.sound = .default
            }
        }
    }

    var userInfo: [AnyHashable: Any] = [
        "accountId": "\(account.account.id.int64)",
        "peerId": "\(id.peerId.toInt64())",
        "msg_id": "\(id.id)",
        "messageId.namespace": id.namespace,
        "messageId.id": id.id
    ]
    if let threadId = message.threadId {
        userInfo["threadId"] = threadId as Int64
    }
    content.userInfo = userInfo

    if showContents {
        for media in message.media {
            let representations: [TelegramMediaImageRepresentation]
            if let image = media as? TelegramMediaImage {
                representations = image.representations
            } else if let file = media as? TelegramMediaFile {
                representations = file.previewRepresentations
            } else { continue }
            if let attachment = conceptNotificationThumbnail(account: account, representations: representations) {
                content.attachments = [attachment]
                break
            }
        }
    }

    let conversationIdentifier = content.threadIdentifier
    let categoryIdentifier = content.categoryIdentifier
    if showContents, #available(iOS 15.0, *) {
        let senderPeer = isChannel ? displayPeer : (authorPeer ?? displayPeer)
        let senderImage = conceptNotificationAvatarFile(account: account, peer: senderPeer)
            .flatMap { try? Data(contentsOf: $0) }.map { INImage(imageData: $0) }
        let senderPerson = INPerson(
            personHandle: INPersonHandle(value: "\(senderPeer.id.toInt64())", type: .unknown),
            nameComponents: nil,
            displayName: isChannel ? chatName : (authorName ?? chatName),
            image: senderImage,
            contactIdentifier: nil,
            customIdentifier: "\(account.account.id.int64)_\(senderPeer.id.toInt64())",
            isMe: false,
            suggestionType: .none
        )
        // The sender and current user are implicit, not recipients of an incoming intent.
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: body,
            speakableGroupName: isGroup ? INSpeakableString(spokenPhrase: conversationName) : nil,
            conversationIdentifier: conversationIdentifier,
            serviceName: "Concept",
            sender: senderPerson,
            attachments: nil
        )
        if let senderImage {
            intent.setImage(senderImage, forParameterNamed: \.sender)
        }
        if isGroup, let avatarURL = conceptNotificationAvatarFile(account: account, peer: displayPeer),
           let data = try? Data(contentsOf: avatarURL) {
            intent.setImage(INImage(imageData: data), forParameterNamed: \.speakableGroupName)
        }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        if let updated = try? content.updating(from: intent).mutableCopy() as? UNMutableNotificationContent {
            content = updated
        }
        // Keep Telegram's chat/author/text layout even when UIKit decorates the icon.
        content.title = title
        content.subtitle = isGroup ? (authorName ?? "") : ""
        content.body = body
    }

    content.userInfo = userInfo
    content.threadIdentifier = conversationIdentifier
    content.categoryIdentifier = categoryIdentifier
    let identifier = "concept_local_\(account.account.id.int64)_\(id.peerId.toInt64())_\(id.namespace)_\(id.id)"
    return ConceptLocalNotificationRequest(identifier: identifier, content: content)
}

private func conceptNotificationPeerName(_ peer: EnginePeer, strings: PresentationStrings, nameDisplayOrder: PresentationPersonNameOrder) -> String {
    let title = peer.displayTitle(strings: strings, displayOrder: nameDisplayOrder)
    if title.isEmpty {
        return peer.compactDisplayTitle
    }
    return title
}

private func conceptNotificationAvatarFile(account: AccountContext, peer: EnginePeer) -> URL? {
    let cachedDirectory = conceptNotificationAvatarCacheDirectory(account: account)
    guard let cachedDirectory else {
        return nil
    }
    let avatar = account.engine.conceptNotificationAvatar(peer: peer)
    let identity: String
    if let avatar, avatar.path != nil {
        identity = "photo-\(avatar.identity)"
    } else {
        identity = "letters-\(peer.id.toInt64())-\(peer.displayLetters.joined())"
    }
    let safeIdentity = String(identity.map { character in
        if character.isLetter || character.isNumber || character == "-" || character == "_" {
            return character
        }
        return "_"
    })
    let cachedPath = (cachedDirectory as NSString).appendingPathComponent("\(safeIdentity).png")
    if !FileManager.default.fileExists(atPath: cachedPath) {
        let image: UIImage?
        if let avatarPath = avatar?.path, let source = UIImage(contentsOfFile: avatarPath) {
            image = conceptNotificationRoundImage(source: source, size: CGSize(width: 180.0, height: 180.0))
        } else {
            image = conceptNotificationLettersImage(size: CGSize(width: 180.0, height: 180.0), peerId: peer.id, letters: peer.displayLetters)
        }
        guard let image, let data = image.pngData() else {
            return nil
        }
        let _ = try? data.write(to: URL(fileURLWithPath: cachedPath), options: .atomic)
    }
    guard FileManager.default.fileExists(atPath: cachedPath) else {
        return nil
    }
    return URL(fileURLWithPath: cachedPath)
}

private func conceptNotificationAvatarCacheDirectory(account: AccountContext) -> String? {
    guard let libraryPath = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first else {
        return nil
    }
    let path = (libraryPath as NSString).appendingPathComponent("ConceptNotificationAvatars/\(account.account.id.int64)")
    if !FileManager.default.fileExists(atPath: path) {
        let _ = try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
    }
    return path
}

private func conceptNotificationRoundImage(source: UIImage, size: CGSize) -> UIImage? {
    UIGraphicsBeginImageContextWithOptions(size, false, 2.0)
    let context = UIGraphicsGetCurrentContext()
    context?.beginPath()
    context?.addEllipse(in: CGRect(origin: .zero, size: size))
    context?.clip()
    source.draw(in: CGRect(origin: .zero, size: size))
    let image = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return image
}

private let conceptNotificationGradientColors: [NSArray] = [
    [UIColor(rgb: 0xff516a).cgColor, UIColor(rgb: 0xff885e).cgColor],
    [UIColor(rgb: 0xffa85c).cgColor, UIColor(rgb: 0xffcd6a).cgColor],
    [UIColor(rgb: 0x665fff).cgColor, UIColor(rgb: 0x82b1ff).cgColor],
    [UIColor(rgb: 0x54cb68).cgColor, UIColor(rgb: 0xa0de7e).cgColor],
    [UIColor(rgb: 0x4acccd).cgColor, UIColor(rgb: 0x00fcfd).cgColor],
    [UIColor(rgb: 0x2a9ef1).cgColor, UIColor(rgb: 0x72d5fd).cgColor],
    [UIColor(rgb: 0xd669ed).cgColor, UIColor(rgb: 0xe0a2f3).cgColor]
]

private func conceptNotificationLettersImage(size: CGSize, peerId: EnginePeer.Id, letters: [String]) -> UIImage? {
    UIGraphicsBeginImageContextWithOptions(size, false, 2.0)
    let context = UIGraphicsGetCurrentContext()
    context?.beginPath()
    context?.addEllipse(in: CGRect(origin: .zero, size: size))
    context?.clip()

    let colorIndex: Int
    if peerId.namespace == .max {
        colorIndex = 0
    } else {
        let raw = peerId.id._internalGetInt64Value() % Int64(conceptNotificationGradientColors.count)
        colorIndex = raw < 0 ? Int(-raw) : Int(raw)
    }
    let colors = conceptNotificationGradientColors[colorIndex % conceptNotificationGradientColors.count]
    var locations: [CGFloat] = [1.0, 0.0]
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: &locations) {
        context?.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0.0, y: size.height), options: [])
    }

    let string = letters.isEmpty ? "" : (letters[0] + (letters.count == 1 ? "" : letters[1]))
    let attributedString = NSAttributedString(string: string, attributes: [
        NSAttributedString.Key.font: UIFont.systemFont(ofSize: 72.0),
        NSAttributedString.Key.foregroundColor: UIColor.white
    ])
    let line = CTLineCreateWithAttributedString(attributedString)
    let lineBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let lineOrigin = CGPoint(x: floor(-lineBounds.origin.x + (size.width - lineBounds.size.width) / 2.0), y: floor(-lineBounds.origin.y + (size.height - lineBounds.size.height) / 2.0))

    context?.translateBy(x: size.width / 2.0, y: size.height / 2.0)
    context?.scaleBy(x: 1.0, y: -1.0)
    context?.translateBy(x: -size.width / 2.0, y: -size.height / 2.0)
    context?.translateBy(x: lineOrigin.x, y: lineOrigin.y)
    if let context {
        CTLineDraw(line, context)
    }
    context?.translateBy(x: -lineOrigin.x, y: -lineOrigin.y)

    let image = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return image
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255.0, green: CGFloat((rgb >> 8) & 0xff) / 255.0, blue: CGFloat(rgb & 0xff) / 255.0, alpha: 1.0)
    }
}
private func conceptNotificationThumbnail(account: AccountContext, representations: [TelegramMediaImageRepresentation]) -> UNNotificationAttachment? {
    guard let directory = conceptNotificationAvatarCacheDirectory(account: account) else { return nil }
    for representation in representations {
        guard let path = account.engine.resources.completedResourcePath(id: EngineMediaResource.Id(representation.resource.id)),
              let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber,
              size.intValue > 0, size.intValue <= 1024 * 1024 else { continue }
        let copy = URL(fileURLWithPath: directory).appendingPathComponent("preview-\(UUID().uuidString).jpg")
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
            defer { try? FileManager.default.removeItem(at: copy) }
            return try UNNotificationAttachment(identifier: "preview", url: copy, options: [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"])
        } catch { continue }
    }
    return nil
}
