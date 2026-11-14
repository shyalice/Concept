import Foundation
import Postbox

func conceptReplaceOutgoingText(_ message: EnqueueMessage, rules: [ConceptTextReplacementRule]) -> EnqueueMessage? {
    guard case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets) = message else { return message }
    // Rich-message documents carry their own structured tree. Do not rewrite
    // only its flattened text and silently corrupt that document.
    guard !attributes.contains(where: { $0 is RichTextMessageAttribute }) else { return message }
    let entities = (attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
    let result = ConceptTextReplacement.apply(text: text, ranges: entities.map(\.range), rules: rules)
    guard result.text != text else { return message }
    if mediaReference == nil && result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
    var updated = attributes.filter { !($0 is TextEntitiesMessageAttribute) }
    let remapped = zip(entities, result.ranges).compactMap { entity, range -> MessageTextEntity? in
        guard let range else { return nil }
        if case .CustomEmoji = entity.type {
            let previous = (text as NSString).substring(with: NSRange(location: entity.range.lowerBound, length: entity.range.count))
            let current = (result.text as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
            guard previous == current else { return nil }
        }
        return MessageTextEntity(range: range, type: entity.type)
    }
    if !remapped.isEmpty { updated.append(TextEntitiesMessageAttribute(entities: remapped)) }
    return .message(text: result.text, attributes: updated, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)
}
