import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

private final class BadgeNotificationSettings: PeerNotificationSettings {
    let muted: Bool
    init(muted: Bool) { self.muted = muted }
    init(decoder: PostboxDecoder) { self.muted = decoder.decodeBoolForKey("m", orElse: false) }
    func encode(_ encoder: PostboxEncoder) { encoder.encodeBool(self.muted, forKey: "m") }
    func isRemovedFromTotalUnreadCount(default: Bool) -> Bool { return self.muted }
    var behavior: PeerNotificationSettingsBehavior { return .none }
    func isEqual(to other: PeerNotificationSettings) -> Bool { return (other as? BadgeNotificationSettings)?.muted == self.muted }
}

/// bugs.telegram.org/c/203: mute a secret chat after receiving a message,
/// then read it. Also cover several secret chats sharing one notification peer.
final class ConceptBadgeUnreadTests: XCTestCase {
    private var fixture: PostboxFixture!
    private let tag = PeerSummaryCounterTags(rawValue: 1)
    private let user = MessageHistoryTableFixture.peerId(710)
    private let first = MessageHistoryTableFixture.peerId(711)
    private let second = MessageHistoryTableFixture.peerId(712)

    private static let register: Void = {
        declareEncodable(BadgeNotificationSettings.self, f: { BadgeNotificationSettings(decoder: $0) })
    }()

    override func setUp() {
        super.setUp()
        let _ = Self.register
        self.fixture = PostboxFixture(name: "ConceptBadgeUnreadTests", seedConfiguration: MessageHistoryTableFixture.makeSeedConfiguration(counterTags: self.tag))
    }

    override func tearDown() {
        self.fixture.close()
        self.fixture = nil
        super.tearDown()
    }

    private func seed(_ peers: [PeerId]) {
        self.fixture.transaction { transaction in
            transaction.updatePeersInternal([FixturePeer(id: self.user, title: "User")] + peers.map { FixturePeer(id: $0, title: "Secret", associatedPeerId: self.user, associatedPeerOverridesIdentity: true) }, update: { _, updated in updated })
            for peer in peers {
                transaction.updatePeerChatListInclusion(peer, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: 1000))
                let id = MessageId(peerId: peer, namespace: 0, id: 1)
                let _ = transaction.addMessages([StoreMessage(id: id, customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: 1001, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: self.user, text: "message", attributes: [], media: [])], location: .Random)
                let lower = MessageIndex(id: MessageId(peerId: peer, namespace: 0, id: 0), timestamp: 0)
                transaction.resetIncomingReadStates([peer: [0: .indexBased(maxIncomingReadIndex: lower, maxOutgoingReadIndex: lower, count: 1, markedUnread: false)]])
            }
        }
    }

    private func mute(_ transaction: Transaction, _ value: Bool = true) {
        transaction.updateCurrentPeerNotificationSettings([self.user: BadgeNotificationSettings(muted: value)])
    }

    private func read(_ transaction: Transaction, peer: PeerId) {
        let _ = transaction.applyInteractiveReadMaxIndex(MessageIndex(id: MessageId(peerId: peer, namespace: 0, id: 1), timestamp: 1001))
    }

    private func assertCounters(absolute: Int32, filtered: Int32, file: StaticString = #filePath, line: UInt = #line) {
        let state = self.fixture.transaction { $0.getTotalUnreadState(groupId: .root) }!
        XCTAssertEqual(state.absoluteCounters[self.tag]?.messageCount ?? 0, absolute, file: file, line: line)
        XCTAssertEqual(state.filteredCounters[self.tag]?.messageCount ?? 0, filtered, file: file, line: line)
    }

    func testMuteThenReadSecretChatLeavesNoBadge() {
        self.seed([self.first])
        self.assertCounters(absolute: 1, filtered: 1)
        self.fixture.transaction { self.mute($0) }
        self.assertCounters(absolute: 1, filtered: 0)
        self.fixture.transaction { self.read($0, peer: self.first) }
        self.assertCounters(absolute: 0, filtered: 0)
        self.fixture.transaction { self.mute($0, false) }
        self.assertCounters(absolute: 0, filtered: 0)
    }

    func testSeveralSecretChatsAllStopContributingWhenMuted() {
        self.seed([self.first, self.second])
        self.assertCounters(absolute: 2, filtered: 2)
        self.fixture.transaction { self.mute($0) }
        self.assertCounters(absolute: 2, filtered: 0)
        self.fixture.transaction {
            self.read($0, peer: self.first)
            self.read($0, peer: self.second)
        }
        self.assertCounters(absolute: 0, filtered: 0)
    }

    func testMuteAndReadInOneTransactionLeaveNoBadge() {
        self.seed([self.first])
        self.fixture.transaction {
            self.mute($0)
            self.read($0, peer: self.first)
        }
        self.assertCounters(absolute: 0, filtered: 0)
    }

    func testHiddenSecretChatDoesNotLeaveAVisibleBadge() {
        self.seed([self.first, self.second])
        self.fixture.transaction { $0.updatePeerIdsExcludedFromUnreadCounters([self.first]) }
        self.assertCounters(absolute: 1, filtered: 1)
        self.fixture.transaction { self.mute($0) }
        self.assertCounters(absolute: 1, filtered: 0)
        self.fixture.transaction { self.read($0, peer: self.second) }
        self.assertCounters(absolute: 0, filtered: 0)
        self.fixture.transaction { $0.updatePeerIdsExcludedFromUnreadCounters([]) }
        self.assertCounters(absolute: 1, filtered: 0)
    }
}
