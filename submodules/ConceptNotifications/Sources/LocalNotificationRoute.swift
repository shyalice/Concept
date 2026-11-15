import Foundation

/// A reply root is a topic only when the conversation supports topics.
public struct LocalNotificationRoute: Hashable {
    public let accountId: Int64
    public let peerId: Int64
    public let messageNamespace: Int32
    public let messageId: Int32
    public let topicId: Int64?

    public init(accountId: Int64, peerId: Int64, messageNamespace: Int32, messageId: Int32, threadId: Int64?, supportsTopics: Bool) {
        self.accountId = accountId
        self.peerId = peerId
        self.messageNamespace = messageNamespace
        self.messageId = messageId
        self.topicId = supportsTopics ? threadId : nil
    }

    public init?(userInfo: [AnyHashable: Any]) {
        func integer(_ key: String) -> Int64? {
            if let value = userInfo[key] as? String { return Int64(value) }
            if let value = userInfo[key] as? NSNumber { return Int64(value.stringValue) }
            return nil
        }
        guard let accountId = integer("accountId"), let peerId = integer("peerId"),
              let rawId = integer("messageId.id") ?? integer("msg_id"), let messageId = Int32(exactly: rawId) else { return nil }
        if userInfo["messageId.namespace"] != nil && integer("messageId.namespace") == nil { return nil }
        let rawNamespace = integer("messageId.namespace") ?? 0
        guard let namespace = Int32(exactly: rawNamespace) else { return nil }
        self.init(accountId: accountId, peerId: peerId, messageNamespace: namespace,
                  messageId: messageId, threadId: integer("threadId"), supportsTopics: true)
    }

    public static let requestsChanged = Notification.Name("ConceptNotificationRequestsChanged")

    public var conversationIdentifier: String {
        let conversation = "\(self.accountId)_\(self.peerId)"
        return self.topicId.map { "\(conversation)_\($0)" } ?? conversation
    }

    public var identifier: String {
        return "concept_local_\(self.accountId)_\(self.peerId)_\(self.messageNamespace)_\(self.messageId)"
    }

    public var userInfo: [AnyHashable: Any] {
        var result: [AnyHashable: Any] = [
            "accountId": String(self.accountId), "peerId": String(self.peerId),
            "msg_id": String(self.messageId),
            "messageId.namespace": self.messageNamespace, "messageId.id": self.messageId
        ]
        if let topicId = self.topicId { result["threadId"] = topicId }
        return result
    }
}
