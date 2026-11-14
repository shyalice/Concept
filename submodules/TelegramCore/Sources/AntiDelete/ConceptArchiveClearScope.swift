import Foundation

/// Selection semantics shared by explicit cache clears. Nil peers/messages means
/// all; an empty set means none. Explicit message additions can span selected peers.
struct ConceptArchiveClearScope<PeerID: Hashable, MessageID: Hashable> {
    let peerIds: Set<PeerID>?
    let messageIds: Set<MessageID>?
    let excludedIds: Set<MessageID>

    var isEmpty: Bool {
        if let peerIds { return peerIds.isEmpty && (self.messageIds?.isEmpty ?? true) }
        return self.messageIds?.isEmpty ?? false
    }

    var isFullClear: Bool {
        return self.peerIds == nil && self.messageIds == nil && self.excludedIds.isEmpty
    }

    func contains(peerId: PeerID, messageId: MessageID) -> Bool {
        if self.excludedIds.contains(messageId) { return false }
        if let peerIds { return peerIds.contains(peerId) || (self.messageIds?.contains(messageId) ?? false) }
        if let messageIds { return messageIds.contains(messageId) }
        return true
    }
}
