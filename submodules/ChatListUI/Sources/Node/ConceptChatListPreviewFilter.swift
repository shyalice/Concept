import TelegramCore
import SwiftSignalKit
import AccountContext

func conceptChatListPreviewUpdates(context: AccountContext, updates: Signal<(ChatListNodeViewUpdate, ChatListFilter?), NoError>) -> Signal<(ChatListNodeViewUpdate, ChatListFilter?, Set<EnginePeer.Id>), NoError> {
    var previousList: EngineChatList?
    return combineLatest(queue: .mainQueue(), updates, ConceptMessageFilterSettings.hideBlockedUsersSignal)
    |> mapToSignal { value, enabled -> Signal<(ChatListNodeViewUpdate, ChatListFilter?, Set<EnginePeer.Id>), NoError> in
        let (update, filter) = value
        var forwardsNavigation = previousList !== update.list
        previousList = update.list
        func result(_ authors: Set<EnginePeer.Id>) -> (ChatListNodeViewUpdate, ChatListFilter?, Set<EnginePeer.Id>) {
            // A block/filter change refreshes previews without replaying a scroll request.
            let mapped = forwardsNavigation ? update : ChatListNodeViewUpdate(list: update.list, type: .Generic, scrollPosition: nil)
            forwardsNavigation = false
            return (mapped, filter, authors)
        }
        guard enabled else { return .single(result([])) }
        let messages = update.list.items.flatMap(\.messages)
            + update.list.additionalItems.flatMap { $0.item.messages }
            + update.list.groupItems.compactMap(\.topMessage)
        let authors = Set(messages.compactMap { $0.author?.id })
        guard !authors.isEmpty else { return .single(result([])) }
        return context.engine.data.subscribe(EngineDataMap(authors.map(TelegramEngine.EngineData.Item.Peer.IsBlocked.init(id:))))
        |> map { blocked in
            result(Set(authors.filter { blocked[$0]?.knownValue == true }))
        }
    }
}

func conceptChatListEntriesHidingBlockedPreviews(_ entries: [ChatListNodeEntry], blockedAuthors: Set<EnginePeer.Id>) -> [ChatListNodeEntry] {
    guard !blockedAuthors.isEmpty else { return entries }
    return entries.map { entry in
        switch entry {
        case var .PeerEntry(data):
            if let author = data.messages.last?.author, blockedAuthors.contains(author.id) {
                data.messages = []
                return .PeerEntry(data)
            }
        case var .GroupReferenceEntry(data):
            if let author = data.message?.author, blockedAuthors.contains(author.id) {
                data.message = nil
                return .GroupReferenceEntry(data)
            }
        default:
            break
        }
        return entry
    }
}
