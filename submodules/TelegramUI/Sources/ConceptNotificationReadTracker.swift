import Foundation
import UserNotifications
import SwiftSignalKit
import TelegramCore
import AccountContext
import ConceptNotifications

/// Watch the synchronized database, including reads performed by another client.
/// Each tracker owns one account; thread read cursors never clear another topic.
final class ConceptNotificationReadTracker {
    private let account: AccountContext
    private let observation = MetaDisposable()
    private let blockedObservation = MetaDisposable()
    private var authorRequests: [EnginePeer.Id: Set<String>] = [:]
    private var requests: [String: LocalNotificationRoute] = [:]
    private var generation = 0
    private var readIdentifiers = Set<String>()

    init(account: AccountContext) {
        self.account = account
        self.refresh()
    }

    func refresh() {
        self.generation += 1
        let generation = self.generation
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { [weak self] delivered in
            center.getPendingNotificationRequests { pending in
                Queue.mainQueue().async {
                    guard let self, self.generation == generation else { return }
                    var requests: [String: LocalNotificationRoute] = [:]
                    for request in delivered.map(\.request) + pending {
                        if let route = LocalNotificationRoute(userInfo: request.content.userInfo), route.accountId == self.account.account.id.int64 {
                            requests[request.identifier] = route
                        }
                    }
                    self.observe(requests)
                }
            }
        }
    }

    private func observe(_ requests: [String: LocalNotificationRoute]) {
        guard requests != self.requests else {
            self.removeReadRequests(Array(self.readIdentifiers.intersection(requests.keys)))
            return
        }
        self.requests = requests
        self.readIdentifiers.formIntersection(requests.keys)
        guard !requests.isEmpty else {
            self.observation.set(nil)
            self.authorRequests.removeAll()
            self.blockedObservation.set(nil)
            return
        }
        let peers = Set(requests.values.map { EnginePeer.Id($0.peerId) })
        let ids = Set(requests.values.map { EngineMessage.Id(peerId: EnginePeer.Id($0.peerId), namespace: $0.messageNamespace, id: $0.messageId) })
        let topics = Set(requests.values.compactMap { route -> TelegramEngine.EngineData.Item.Peer.ThreadData.Key? in
            guard let topicId = route.topicId else { return nil }
            return .init(id: EnginePeer.Id(route.peerId), threadId: topicId)
        })
        self.observation.set((self.account.engine.data.subscribe(
            EngineDataMap(peers.map(TelegramEngine.EngineData.Item.Messages.PeerReadCounters.init(id:))),
            EngineDataMap(ids.map(TelegramEngine.EngineData.Item.Messages.Message.init(id:))),
            EngineDataMap(topics.map { TelegramEngine.EngineData.Item.Peer.ThreadData(id: $0.id, threadId: $0.threadId) }),
            EngineDataMap(peers.map(TelegramEngine.EngineData.Item.Peer.Peer.init(id:)))
        ) |> deliverOnMainQueue).start(next: { [weak self] counters, messages, threads, peers in
            guard let self else { return }
            var remove: [String] = []
            var authorRequests: [EnginePeer.Id: Set<String>] = [:]
            for (identifier, route) in self.requests {
                let peerId = EnginePeer.Id(route.peerId)
                let id = EngineMessage.Id(peerId: peerId, namespace: route.messageNamespace, id: route.messageId)
                let message: EngineMessage? = messages[id] ?? nil
                if let authorId = message?.author?.id { authorRequests[authorId, default: []].insert(identifier) }
                let peer = peers[peerId] ?? nil
                let supportsTopics = peer?._asPeer().isForumOrMonoForum ?? false
                let read: Bool
                if supportsTopics, let topicId = route.topicId {
                    let key = TelegramEngine.EngineData.Item.Peer.ThreadData.Key(id: peerId, threadId: topicId)
                    read = (threads[key] ?? nil).map { route.messageId <= $0.maxIncomingReadId } ?? false
                } else if route.topicId != nil && peer == nil {
                    read = false
                } else if let counter = counters[peerId] {
                    if let message {
                        read = counter.isIncomingMessageIndexRead(message.index)
                    } else if route.messageNamespace == Namespaces.Message.Cloud {
                        read = counter.isIncomingMessageIndexRead(EngineMessage.Index(id: id, timestamp: 0))
                    } else {
                        read = false
                    }
                } else {
                    read = false
                }
                if read { remove.append(identifier) }
            }
            self.observeBlockedAuthors(authorRequests)
            self.readIdentifiers = Set(remove)
            guard !remove.isEmpty else { return }
            self.removeReadRequests(remove)
            // Keep this subscription until the next refresh: a late delivery with the same
            // identity must still be removable after the server has advanced its read cursor.
        }))
    }

    private func removeReadRequests(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private func observeBlockedAuthors(_ requests: [EnginePeer.Id: Set<String>]) {
        guard requests != self.authorRequests else { return }
        self.authorRequests = requests
        self.blockedObservation.set((combineLatest(
            self.account.engine.data.subscribe(EngineDataMap(requests.keys.map { TelegramEngine.EngineData.Item.Peer.IsBlocked(id: $0) })),
            ConceptMessageFilterSettings.hideBlockedUsersSignal
        ) |> deliverOnMainQueue).start(next: { [weak self] blocked, enabled in
            guard let self, enabled else { return }
            let identifiers = requests.filter { blocked[$0.key]?.knownValue == true }.flatMap { $0.value }
            self.removeReadRequests(identifiers)
        }))
    }

    deinit {
        self.observation.dispose()
        self.blockedObservation.dispose()
    }
}
