import Foundation
import Postbox

/// Stored with the message in its account's encrypted Postbox, including in extensions.
public final class ConceptEditHistoryMessageAttribute: MessageAttribute {
    private let decodedRevisions: [ConceptMessageRevision]?
    private let encodedRevisions: Data?

    public var revisions: [ConceptMessageRevision] {
        if let decodedRevisions { return decodedRevisions }
        guard let encodedRevisions else { return [] }
        return (try? JSONDecoder().decode([ConceptMessageRevision].self, from: encodedRevisions)) ?? []
    }

    public init(revisions: [ConceptMessageRevision]) {
        self.decodedRevisions = revisions
        self.encodedRevisions = nil
    }

    public init(decoder: PostboxDecoder) {
        self.decodedRevisions = nil
        self.encodedRevisions = decoder.decodeDataForKey("v")
    }

    public func encode(_ encoder: PostboxEncoder) {
        if let data = self.encodedRevisions ?? (try? JSONEncoder().encode(self.decodedRevisions ?? [])) {
            encoder.encodeData(data, forKey: "v")
        }
    }
}

private func conceptFormattingData(_ attributes: [MessageAttribute]) -> Data? {
    let formatting = attributes.filter { $0 is TextEntitiesMessageAttribute || $0 is RichTextMessageAttribute }
    guard !formatting.isEmpty else { return nil }
    let encoder = PostboxEncoder()
    encoder.encodeGenericObjectArray(formatting, forKey: "a")
    return encoder.makeData()
}

public func conceptVisibleMessageRevisions(message: EngineMessage) -> [ConceptMessageRevision] {
    let message = message._asMessage()
    let revisions = message.attributes.compactMap { $0 as? ConceptEditHistoryMessageAttribute }.first?.revisions ?? []
    return ConceptEditHistory.visibleRevisions(revisions, currentText: message.text, currentFormattingData: conceptFormattingData(message.attributes))
}

/// Runs inside every Postbox replacement, including notification and history-fill updates.
func conceptMergeMessageContentAttributes(
    previousText: String,
    previousTimestamp: Int32,
    previousAttributes: [MessageAttribute],
    updatedText: String,
    updatedAttributes: inout [MessageAttribute]
) {
    if let deleted = previousAttributes.first(where: { $0 is DeletedMessageAttribute }),
       !updatedAttributes.contains(where: { $0 is DeletedMessageAttribute }) {
        updatedAttributes.append(deleted)
    }
    let previousHistory = previousAttributes.compactMap { $0 as? ConceptEditHistoryMessageAttribute }.first
    let previousEditDate = previousAttributes.compactMap { $0 as? EditedMessageAttribute }.first?.date
    let updatedEditDate = updatedAttributes.compactMap { $0 as? EditedMessageAttribute }.first?.date
    let previousEntities = (previousAttributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
    let updatedEntities = (updatedAttributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
    let previousRichText = previousAttributes.first(where: { $0 is RichTextMessageAttribute }) as? RichTextMessageAttribute
    let updatedRichText = updatedAttributes.first(where: { $0 is RichTextMessageAttribute }) as? RichTextMessageAttribute
    if updatedEditDate == nil || (previousText == updatedText && previousEntities == updatedEntities && previousRichText == updatedRichText) {
        // View counters, reactions and read-state writes reuse the stored bytes;
        // they must not decode or rewrite the entire revision list.
        if let previousHistory {
            updatedAttributes.removeAll(where: { $0 is ConceptEditHistoryMessageAttribute })
            updatedAttributes.append(previousHistory)
        }
        return
    }
    let previous = ConceptMessageRevision(
        text: previousText,
        timestamp: previousEditDate ?? previousTimestamp,
        formattingData: conceptFormattingData(previousAttributes)
    )
    let revisions = ConceptEditHistory.appendingPreviousVersion(
        to: previousHistory?.revisions ?? [],
        previous: previous,
        previousEditDate: previousEditDate,
        updatedText: updatedText,
        updatedFormattingData: conceptFormattingData(updatedAttributes),
        updatedEditDate: updatedEditDate
    )
    let supplied = updatedAttributes.compactMap { $0 as? ConceptEditHistoryMessageAttribute }.first
    if let supplied, supplied.revisions.count > revisions.count {
        return
    }
    updatedAttributes.removeAll(where: { $0 is ConceptEditHistoryMessageAttribute })
    if !revisions.isEmpty {
        updatedAttributes.append(ConceptEditHistoryMessageAttribute(revisions: revisions))
    }
}
