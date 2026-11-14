import Foundation
import Postbox
import SwiftSignalKit

private struct ConceptArchivedMediaPins: Codable {
    let resourceIds: [String]
}

private func conceptCollectArchivedMediaResources(_ media: Media, ids: inout Set<MediaResourceId>) {
    if let image = media as? TelegramMediaImage {
        for representation in image.representations { ids.insert(representation.resource.id) }
        for representation in image.videoRepresentations { ids.insert(representation.resource.id) }
    } else if let file = media as? TelegramMediaFile {
        ids.insert(file.resource.id)
        for representation in file.previewRepresentations { ids.insert(representation.resource.id) }
    } else if let paid = media as? TelegramMediaPaidContent {
        for case let .full(media) in paid.extendedMedia {
            conceptCollectArchivedMediaResources(media, ids: &ids)
        }
    } else if let invoice = media as? TelegramMediaInvoice, let extended = invoice.extendedMedia, case let .full(media) = extended {
        conceptCollectArchivedMediaResources(media, ids: &ids)
    } else if let webpage = media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content {
        if let image = content.image { conceptCollectArchivedMediaResources(image, ids: &ids) }
        if let file = content.file { conceptCollectArchivedMediaResources(file, ids: &ids) }
    }
}

/// Store compact resource identities separately from archived text, so pinning
/// does not decode a potentially large deletion history on every account launch.
func conceptPinArchivedMessageMedia(transaction: Transaction, message: Message) {
    guard AntiDeleteManager.shared.archiveMedia else { return }
    var ids = Set<MediaResourceId>()
    for media in message.effectiveMedia {
        conceptCollectArchivedMediaResources(media, ids: &ids)
    }
    guard !ids.isEmpty, let entry = CodableEntry(ConceptArchivedMediaPins(resourceIds: ids.map { $0.stringRepresentation }.sorted())) else { return }
    let key = MemoryBuffer(data: Data("\(message.id.peerId.toInt64()):\(message.id.namespace):\(message.id.id)".utf8))
    transaction.addOrMoveToFirstPositionOrderedItemListItem(collectionId: Namespaces.OrderedItemList.conceptArchivedMediaPins, item: OrderedItemListEntry(id: key, contents: entry), removeTailIfCountExceeds: nil)
}

/// Rehydrates persistent archive pins before the account starts automatic cache
/// eviction. Existing MediaBox leases protect cached/partially cached originals;
/// explicit force-clears still follow the normal MediaBox behavior.
final class ConceptArchivedMediaContext {
    private let queue = Queue(name: "ConceptArchivedMedia")
    private let disposable = MetaDisposable()
    private var resources: [MediaResourceId: Disposable] = [:]

    init(postbox: Postbox) {
        let key = PostboxViewKey.orderedItemList(id: Namespaces.OrderedItemList.conceptArchivedMediaPins)
        self.disposable.set((postbox.combinedView(keys: [key]) |> deliverOn(self.queue)).start(next: { [weak self] views in
            guard let self, let view = views.views[key] as? OrderedItemListView else { return }
            var wanted = Set<MediaResourceId>()
            for item in view.items {
                if let pins = item.contents.get(ConceptArchivedMediaPins.self) {
                    for id in pins.resourceIds { wanted.insert(MediaResourceId(id)) }
                }
            }
            for id in Array(self.resources.keys) where !wanted.contains(id) {
                self.resources.removeValue(forKey: id)?.dispose()
            }
            for id in wanted where self.resources[id] == nil {
                self.resources[id] = postbox.mediaBox.keepResource(id: id).start()
            }
        }))
    }

    deinit {
        self.disposable.dispose()
        for resource in self.resources.values { resource.dispose() }
    }
}
