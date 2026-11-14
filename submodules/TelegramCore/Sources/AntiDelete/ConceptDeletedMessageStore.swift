import Foundation
import Postbox
import SwiftSignalKit

private func conceptArchivedMessageKey(_ id: MessageId) -> MemoryBuffer {
    return MemoryBuffer(data: Data("\(id.peerId.toInt64()):\(id.namespace):\(id.id)".utf8))
}

private struct ConceptNotificationPreview: Codable {
    let peerId: Int64
    let messageId: Int32
    let receivedAt: Int32
    let text: String

    var id: MessageId {
        return MessageId(peerId: PeerId(self.peerId), namespace: Namespaces.Message.Cloud, id: self.messageId)
    }
}

private func conceptNotificationPreviewKey(_ id: MessageId) -> MemoryBuffer {
    // Private/basic-group ids are account-global. This also lets a global-id
    // deletion find a preview when the full message was never fetched.
    if id.peerId.namespace != Namespaces.Peer.CloudChannel {
        return MemoryBuffer(data: Data("g:\(id.id)".utf8))
    }
    return conceptArchivedMessageKey(id)
}

/// Persist only a decrypted ordinary-message preview, before any network fetch.
/// This does not insert a fake chat message or change unread/read state.
public func _internal_conceptStoreNotificationPreview(transaction: Transaction, id: MessageId, text: String, receivedAt: Int32) {
    guard AntiDeleteManager.shared.isEnabled, id.namespace == Namespaces.Message.Cloud,
          id.peerId.namespace == Namespaces.Peer.CloudUser || id.peerId.namespace == Namespaces.Peer.CloudGroup || id.peerId.namespace == Namespaces.Peer.CloudChannel,
          !text.isEmpty else { return }
    let preview = ConceptNotificationPreview(peerId: id.peerId.toInt64(), messageId: id.id, receivedAt: receivedAt, text: text)
    guard let entry = CodableEntry(preview) else { return }
    transaction.addOrMoveToFirstPositionOrderedItemListItem(
        collectionId: Namespaces.OrderedItemList.conceptNotificationPreviews,
        item: OrderedItemListEntry(id: conceptNotificationPreviewKey(id), contents: entry),
        removeTailIfCountExceeds: 5000
    )
}

func conceptMessageIdsForReceivedGlobalDeletion(transaction: Transaction, ids: [Int32]) -> [MessageId] {
    var result = transaction.messageIdsForGlobalIds(ids)
    var known = Set(result)
    for id in ids {
        let key = MemoryBuffer(data: Data("g:\(id)".utf8))
        if let preview = transaction.getOrderedItemListItem(collectionId: Namespaces.OrderedItemList.conceptNotificationPreviews, itemId: key)?.contents.get(ConceptNotificationPreview.self), known.insert(preview.id).inserted {
            result.append(preview.id)
        }
    }
    return result
}

private func conceptArchiveNotificationPreview(transaction: Transaction, id: MessageId, deletedAt: Int32) {
    let key = conceptNotificationPreviewKey(id)
    guard let preview = transaction.getOrderedItemListItem(collectionId: Namespaces.OrderedItemList.conceptNotificationPreviews, itemId: key)?.contents.get(ConceptNotificationPreview.self), preview.id == id else { return }
    let archiveKey = conceptArchivedMessageKey(id)
    if transaction.getOrderedItemListItem(collectionId: Namespaces.OrderedItemList.conceptDeletedMessages, itemId: archiveKey) == nil,
       let entry = CodableEntry(AntiDeleteManager.ArchivedMessage(globalId: id.id, peerId: preview.peerId, messageId: id.id, timestamp: preview.receivedAt, deletedAt: deletedAt, authorId: nil, text: preview.text, forwardAuthorId: nil, mediaDescription: nil, notificationPreview: true)) {
        transaction.addOrMoveToFirstPositionOrderedItemListItem(collectionId: Namespaces.OrderedItemList.conceptDeletedMessages, item: OrderedItemListEntry(id: archiveKey, contents: entry), removeTailIfCountExceeds: nil)
    }
    transaction.removeOrderedItemListItem(collectionId: Namespaces.OrderedItemList.conceptNotificationPreviews, itemId: key)
}

private struct ConceptLegacyArchiveMigration: Codable {
    let completed: Bool
}

private var conceptLegacyArchiveMigrationId: MemoryBuffer {
    return MemoryBuffer(data: Data("concept.legacy-migration.v1".utf8))
}

private func conceptArchiveMigrationMarker() -> OrderedItemListEntry? {
    guard let entry = CodableEntry(ConceptLegacyArchiveMigration(completed: true)) else { return nil }
    return OrderedItemListEntry(id: conceptLegacyArchiveMigrationId, contents: entry)
}

private func conceptMigrateLegacyArchive(transaction: Transaction) {
    if transaction.getOrderedItemListItem(collectionId: Namespaces.OrderedItemList.conceptDeletedMessages, itemId: conceptLegacyArchiveMigrationId)?.contents.get(ConceptLegacyArchiveMigration.self)?.completed == true {
        return
    }
    // The old format omitted the account. Import only records whose content,
    // date and author match this account's message, never guesses from bare ids.
    for archived in AntiDeleteManager.shared.getAllArchivedMessages() {
        let id = MessageId(peerId: PeerId(archived.peerId), namespace: Namespaces.Message.Cloud, id: archived.messageId)
        guard let message = transaction.getMessage(id), message.text == archived.text,
              message.timestamp == archived.timestamp, message.author?.id.toInt64() == archived.authorId else {
            continue
        }
        let key = conceptArchivedMessageKey(id)
        if transaction.getOrderedItemListItem(collectionId: Namespaces.OrderedItemList.conceptDeletedMessages, itemId: key) == nil,
           let entry = CodableEntry(archived) {
            transaction.addOrMoveToFirstPositionOrderedItemListItem(collectionId: Namespaces.OrderedItemList.conceptDeletedMessages, item: OrderedItemListEntry(id: key, contents: entry), removeTailIfCountExceeds: nil)
        }
        conceptPinArchivedMessageMedia(transaction: transaction, message: message)
        if !message.isDeletedButVisible {
            transaction.updateMessage(id, update: { current in
                return .update(StoreMessage(updating: current, attributes: current.attributes + [DeletedMessageAttribute(deletedAt: archived.deletedAt)], tags: current.tags))
            })
        }
    }
    if let marker = conceptArchiveMigrationMarker() {
        transaction.addOrMoveToFirstPositionOrderedItemListItem(collectionId: Namespaces.OrderedItemList.conceptDeletedMessages, item: marker, removeTailIfCountExceeds: nil)
    }
}

private func conceptArchivedMediaDescription(_ message: Message) -> String? {
    for media in message.media {
        if media is TelegramMediaImage {
            return "Photo"
        } else if let file = media as? TelegramMediaFile {
            if file.isInstantVideo { return "Video Message" }
            if file.isVideo { return "Video" }
            if file.isVoice { return "Voice" }
            if file.isSticker { return "Sticker" }
            return file.fileName ?? "File"
        } else if media is TelegramMediaContact {
            return "Contact"
        } else if media is TelegramMediaMap {
            return "Location"
        } else if let poll = media as? TelegramMediaPoll {
            return "Poll: \(poll.text)"
        }
    }
    return nil
}

/// Returns messages still needing physical deletion. The archive and tombstone
/// commit atomically in the same account database as the received server update.
public func _internal_conceptRetainDeletedMessages(transaction: Transaction, ids: [MessageId]) -> [MessageId] {
    guard AntiDeleteManager.shared.isEnabled else { return ids }
    var remaining: [MessageId] = []
    let deletedAt = Int32(clamping: Int64(Date().timeIntervalSince1970))
    for id in ids {
        guard id.namespace == Namespaces.Message.Cloud else {
            remaining.append(id)
            continue
        }
        guard let message = transaction.getMessage(id) else {
            conceptArchiveNotificationPreview(transaction: transaction, id: id, deletedAt: deletedAt)
            remaining.append(id)
            continue
        }
        let key = conceptArchivedMessageKey(id)
        conceptPinArchivedMessageMedia(transaction: transaction, message: message)
        let previous = transaction.getOrderedItemListItem(collectionId: Namespaces.OrderedItemList.conceptDeletedMessages, itemId: key)?.contents.get(AntiDeleteManager.ArchivedMessage.self)
        if previous == nil || previous?.notificationPreview == true {
            let archived = AntiDeleteManager.ArchivedMessage(
                globalId: id.id,
                peerId: id.peerId.toInt64(),
                messageId: id.id,
                timestamp: message.timestamp,
                deletedAt: previous?.deletedAt ?? deletedAt,
                authorId: message.author?.id.toInt64(),
                text: message.text,
                forwardAuthorId: message.forwardInfo?.author?.id.toInt64(),
                mediaDescription: conceptArchivedMediaDescription(message)
            )
            if let entry = CodableEntry(archived) {
                transaction.addOrMoveToFirstPositionOrderedItemListItem(
                    collectionId: Namespaces.OrderedItemList.conceptDeletedMessages,
                    item: OrderedItemListEntry(id: key, contents: entry),
                    removeTailIfCountExceeds: nil
                )
            }
        }
        if !message.attributes.contains(where: { $0 is DeletedMessageAttribute }) {
            transaction.updateMessage(id, update: { current in
                return .update(StoreMessage(updating: current, attributes: current.attributes + [DeletedMessageAttribute(deletedAt: deletedAt)], tags: current.tags))
            })
        }
        transaction.removeOrderedItemListItem(collectionId: Namespaces.OrderedItemList.conceptNotificationPreviews, itemId: conceptNotificationPreviewKey(id))
    }
    return remaining
}

public extension TelegramEngine.Messages {
    func conceptDeletedMessages(limit: Int? = nil) -> Signal<[AntiDeleteManager.ArchivedMessage], NoError> {
        let key = PostboxViewKey.orderedItemList(id: Namespaces.OrderedItemList.conceptDeletedMessages)
        return self.account.postbox.transaction { transaction in
            conceptMigrateLegacyArchive(transaction: transaction)
        }
        |> mapToSignal { _ in
            return self.account.postbox.combinedView(keys: [key])
            |> map { views in
                guard let view = views.views[key] as? OrderedItemListView else { return [] }
                let messages = view.items.lazy.compactMap { $0.contents.get(AntiDeleteManager.ArchivedMessage.self) }
                if let limit { return Array(messages.prefix(max(0, limit))) }
                return Array(messages)
            }
        }
    }

    func clearConceptDeletedMessageArchive() -> Signal<Void, NoError> {
        return self.account.postbox.transaction { transaction in
            // Keep the migration marker so clearing the new archive cannot
            // re-import the old process-local archive on the next subscription.
            transaction.replaceOrderedItemListItems(collectionId: Namespaces.OrderedItemList.conceptDeletedMessages, items: conceptArchiveMigrationMarker().map { [$0] } ?? [])
            transaction.replaceOrderedItemListItems(collectionId: Namespaces.OrderedItemList.conceptArchivedMediaPins, items: [])
        }
    }
}

/// Runs only for an explicit cache-clear request. The migration marker remains
/// so legacy process-local history cannot silently reappear afterwards.
func _internal_conceptClearDeletedArchive(account: Account, peerIds: Set<PeerId>?, messageIds: Set<MessageId>?, excludedIds: Set<MessageId>) -> Signal<Void, NoError> {
    let scope = ConceptArchiveClearScope(peerIds: peerIds, messageIds: messageIds, excludedIds: excludedIds)
    guard !scope.isEmpty else { return .single(()) }
    return account.postbox.transaction { transaction in
        if scope.isFullClear {
            transaction.replaceOrderedItemListItems(collectionId: Namespaces.OrderedItemList.conceptDeletedMessages, items: conceptArchiveMigrationMarker().map { [$0] } ?? [])
            transaction.replaceOrderedItemListItems(collectionId: Namespaces.OrderedItemList.conceptArchivedMediaPins, items: [])
            transaction.replaceOrderedItemListItems(collectionId: Namespaces.OrderedItemList.conceptNotificationPreviews, items: [])
            return
        }
        // A partial clear must migrate first: marking an empty modern archive
        // complete would otherwise hide legacy records from unrelated chats.
        conceptMigrateLegacyArchive(transaction: transaction)
        var retained: [OrderedItemListEntry] = []
        for item in transaction.getOrderedListItems(collectionId: Namespaces.OrderedItemList.conceptDeletedMessages) {
            guard let message = item.contents.get(AntiDeleteManager.ArchivedMessage.self) else { retained.append(item); continue }
            let id = MessageId(peerId: PeerId(message.peerId), namespace: Namespaces.Message.Cloud, id: message.messageId)
            if scope.contains(peerId: id.peerId, messageId: id) {
                transaction.removeOrderedItemListItem(collectionId: Namespaces.OrderedItemList.conceptArchivedMediaPins, itemId: item.id)
            } else { retained.append(item) }
        }
        if !retained.contains(where: { $0.id == conceptLegacyArchiveMigrationId }), let marker = conceptArchiveMigrationMarker() { retained.append(marker) }
        transaction.replaceOrderedItemListItems(collectionId: Namespaces.OrderedItemList.conceptDeletedMessages, items: retained)
        let previews = transaction.getOrderedListItems(collectionId: Namespaces.OrderedItemList.conceptNotificationPreviews).filter { item in
            guard let preview = item.contents.get(ConceptNotificationPreview.self) else { return true }
            return !scope.contains(peerId: preview.id.peerId, messageId: preview.id)
        }
        transaction.replaceOrderedItemListItems(collectionId: Namespaces.OrderedItemList.conceptNotificationPreviews, items: previews)
    }
}
