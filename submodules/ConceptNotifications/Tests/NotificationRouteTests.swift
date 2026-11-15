import XCTest
@testable import ConceptNotifications

final class NotificationRouteTests: XCTestCase {
    func testOrdinaryGroupReplyDoesNotOpenAThread() throws {
        let route = LocalNotificationRoute(accountId: 11, peerId: -1234, messageNamespace: 0, messageId: 456, threadId: 1, supportsTopics: false)
        XCTAssertNil(route.topicId)
        XCTAssertNil(route.userInfo["threadId"])
        XCTAssertEqual(route.conversationIdentifier, "11_-1234")
        let json = try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: route.userInfo.map { (String(describing:$0.key),$0.value) }))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with:json) as? [String:Any])
        XCTAssertEqual(LocalNotificationRoute(userInfo: payload), route)
    }
    func testTopicAndAccountRoutingRemainIndependent() {
        let a = LocalNotificationRoute(accountId: 11, peerId: 4321, messageNamespace: 0, messageId: 456, threadId: 99, supportsTopics: true)
        let b = LocalNotificationRoute(accountId: 12, peerId: 4321, messageNamespace: 0, messageId: 456, threadId: 99, supportsTopics: true)
        let c = LocalNotificationRoute(accountId: 11, peerId: 4321, messageNamespace: 0, messageId: 457, threadId: 100, supportsTopics: true)
        XCTAssertNotEqual(a.identifier,b.identifier)
        XCTAssertNotEqual(a.conversationIdentifier,c.conversationIdentifier)
        XCTAssertEqual(LocalNotificationRoute(userInfo:a.userInfo)?.topicId,99)
    }
    func testMalformedPayloadCannotResolveAnotherMessage() {
        XCTAssertNil(LocalNotificationRoute(userInfo:["accountId":"a", "peerId":"4", "msg_id":"1"]))
        XCTAssertNil(LocalNotificationRoute(userInfo:["accountId":"1", "peerId":"4", "msg_id":"2147483648"]))
        XCTAssertNil(LocalNotificationRoute(userInfo:["accountId":"1", "peerId":"4"]))
        XCTAssertNil(LocalNotificationRoute(userInfo:["accountId":"1", "peerId":"4", "msg_id":"1", "messageId.namespace":"invalid"]))
    }
    func testNativeNotificationPayloadUsesCloudMessageNamespace() {
        let route = LocalNotificationRoute(userInfo:["accountId":"11", "peerId":"4321", "msg_id":"456"])
        XCTAssertEqual(route?.messageNamespace,0)
        XCTAssertEqual(route?.accountId,11)
    }
    func testPerChatActionsOverrideGlobalAndCombine() {
        func policy(_ chat: String?, _ pinned: Bool, _ mention: Bool, _ enabled: Bool = true) -> NotificationPresentationPolicy {
            NotificationPresentationPolicy(enabled:enabled,isPinned:pinned,isMentionOrReply:mention,chatId:chat,pinnedAction:"disabled",pinnedExceptions:["42":"default"],mentionAction:"default",mentionExceptions:["42":"silenced","43":"disabled"])
        }
        XCTAssertTrue(policy(nil,true,false).suppress)
        XCTAssertFalse(policy("42",true,false).suppress)
        XCTAssertTrue(policy("42",false,true).silence)
        XCTAssertTrue(policy("43",false,true).suppress)
        XCTAssertFalse(policy(nil,false,false).suppress)
        XCTAssertFalse(policy("43",false,true,false).suppress)
    }
}
