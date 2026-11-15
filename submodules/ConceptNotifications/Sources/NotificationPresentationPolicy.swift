import Foundation

/// Swiftgram's per-chat exception takes precedence over its global action.
public struct NotificationPresentationPolicy {
    public let suppress: Bool
    public let silence: Bool

    public init(enabled: Bool, isPinned: Bool, isMentionOrReply: Bool, chatId: String?, pinnedAction: String, pinnedExceptions: [String: String], mentionAction: String, mentionExceptions: [String: String]) {
        let pinned = chatId.flatMap { pinnedExceptions[$0] } ?? pinnedAction
        let mention = chatId.flatMap { mentionExceptions[$0] } ?? mentionAction
        self.suppress = enabled && ((isPinned && pinned == "disabled") || (isMentionOrReply && mention == "disabled"))
        self.silence = enabled && ((isPinned && pinned == "silenced") || (isMentionOrReply && mention == "silenced"))
    }
}
