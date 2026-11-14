import Foundation
import Postbox
import SwiftSignalKit

public struct EngineBackgroundNotificationCandidate {
    public let message: EngineMessage
    public let displayContents: Bool
    public let sound: PeerMessageSound
    public let topicTitle: String?
}

struct BackgroundNotificationClaim: Codable {
    let token: String
    let expires: TimeInterval
}

private func displayedMessageKey(_ id: MessageId) -> ItemCacheEntryId {
    let key = ValueBoxKey(length: 12)
    key.setInt64(0, value: id.peerId.toInt64())
    key.setInt32(8, value: id.id)
    return ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.displayedMessageNotifications, key: key)
}

public struct EngineConceptNotificationAvatar {
    public let path: String?
    public let identity: String

    public init(path: String?, identity: String) {
        self.path = path
        self.identity = identity
    }
}

public extension TelegramEngine {
    /// The already-downloaded small profile photo of a peer, for a notification attachment.
    /// `path` is nil when the photo is not cached; the caller can draw initials instead.
    func conceptNotificationAvatar(peer: EnginePeer) -> EngineConceptNotificationAvatar? {
        guard let representation = peer.smallProfileImage else {
            return nil
        }
        let mediaBox = self.account.postbox.mediaBox
        return EngineConceptNotificationAvatar(
            path: mediaBox.completedResourcePath(representation.resource),
            identity: representation.resource.id.stringRepresentation
        )
    }

    func prepareConceptNotificationAvatar(peer: EnginePeer) -> Signal<Never, NoError> {
        guard let representation = peer.smallProfileImage,
              self.account.postbox.mediaBox.completedResourcePath(representation.resource) == nil,
              let reference = PeerReference(peer._asPeer()) else {
            return .complete()
        }
        return fetchedMediaResource(mediaBox: self.account.postbox.mediaBox,
            userLocation: .peer(peer.id), userContentType: .avatar,
            reference: .avatar(peer: reference, resource: representation.resource),
            continueInBackground: true)
        |> ignoreValues
        |> `catch` { _ in .complete() }
    }

}

public extension TelegramEngine.Messages {
    /// A state refresh, not a perpetual socket or read acknowledgement. The UI
    /// owner supplies a bounded service-master lease and disposes it on expiry.
    func refreshBackgroundNotificationCandidates() -> Signal<[EngineBackgroundNotificationCandidate], NoError> {
        let account = self.account
        return Signal<[MessageId], NoError> { subscriber in
            account.stateManager.reset()
            return account.stateManager.pollStateUpdateCompletion().start(next: subscriber.putNext, completed: subscriber.putCompletion)
        }
        |> mapToSignal { ids in
            return account.postbox.transaction { transaction -> [EngineBackgroundNotificationCandidate] in
                var result: [EngineBackgroundNotificationCandidate] = []
                var seen = Set<MessageId>()
                // Avoid an alert storm after a long offline interval.
                for id in ids.reversed() where seen.insert(id).inserted {
                    if result.count >= 10 { break }
                    let notification = messagesForNotification(transaction: transaction, id: id, alwaysReturnMessage: false)
                    guard notification.notify, let message = notification.messages.first(where: { $0.id == id }), message.flags.contains(.Incoming),
                          !_internal_getMessageNotificationWasDisplayed(transaction: transaction, id: message.id) else { continue }
                    result.append(EngineBackgroundNotificationCandidate(message: EngineMessage(message), displayContents: notification.displayContents, sound: notification.sound, topicTitle: notification.threadData?.info.title))
                }
                return result.reversed()
            }
        }
    }

    func claimBackgroundNotification(id: MessageId, token: String) -> Signal<EngineBackgroundNotificationCandidate?, NoError> {
        return self.account.postbox.transaction { transaction -> EngineBackgroundNotificationCandidate? in
            guard !_internal_getMessageNotificationWasDisplayed(transaction: transaction, id: id) else { return nil }
            // Read/mute/content may have changed since the background state sync.
            let notification = messagesForNotification(transaction: transaction, id: id, alwaysReturnMessage: false)
            guard notification.notify, let message = notification.messages.first(where: { $0.id == id }),
                  message.flags.contains(.Incoming),
                  let marker = CodableEntry(BackgroundNotificationClaim(token: token, expires: Date().timeIntervalSince1970 + 60)) else { return nil }
            for media in message.media {
                guard let action = media as? TelegramMediaAction else { continue }
                switch action.action {
                case .unknown, .historyCleared, .phoneCall, .groupMigratedToChannel, .channelMigratedFromGroup,
                     .botDomainAccessGranted, .botAppAccessGranted, .botSentSecureValues, .attachMenuBotAllowed, .webViewData:
                    return nil
                default:
                    break
                }
            }
            transaction.putItemCacheEntry(id: displayedMessageKey(id), entry: marker)
            return EngineBackgroundNotificationCandidate(message: EngineMessage(message), displayContents: notification.displayContents, sound: notification.sound, topicTitle: notification.threadData?.info.title)
        }
    }

    func commitBackgroundNotificationClaim(id: MessageId, token: String) -> Signal<Void, NoError> {
        return self.account.postbox.transaction { transaction in
            let key = displayedMessageKey(id)
            guard transaction.retrieveItemCacheEntry(id: key)?.get(BackgroundNotificationClaim.self)?.token == token else { return }
            _internal_setMessageNotificationWasDisplayed(transaction: transaction, id: id)
        }
    }

    func releaseBackgroundNotificationClaim(id: EngineMessage.Id, token: String) -> Signal<Never, NoError> {
        return self.account.postbox.transaction { transaction -> Void in
            let key = displayedMessageKey(id)
            if transaction.retrieveItemCacheEntry(id: key)?.get(BackgroundNotificationClaim.self)?.token == token {
                transaction.removeItemCacheEntry(id: key)
            }
        } |> ignoreValues
    }
}
