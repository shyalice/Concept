import Foundation
import SGAppGroupIdentifier

// MARK: Swiftgram
let groupUserDefaults: UserDefaults? = UserDefaults(suiteName: sgAppGroupIdentifier())
var sgLegacyNotificationsFix: Bool {
    return !sgHasNotificationFilteringEntitlement() || (groupUserDefaults?.bool(forKey: "legacyNotificationsFix") ?? false)
}
var sgPinnedMessageAction: String {
    return groupUserDefaults?.string(forKey: "pinnedMessageNotifications") ?? "default"
}
var sgPinnedMessageActionExceptions: [String: String] {
    return (groupUserDefaults?.dictionary(forKey: "pinnedMessageNotificationsExceptions") as? [String: String]) ?? [:]
}
var sgMentionAndReplyAction: String {
    return groupUserDefaults?.string(forKey: "mentionsAndRepliesNotifications") ?? "default"
}
var sgMentionAndReplyActionExceptions: [String: String] {
    return (groupUserDefaults?.dictionary(forKey: "mentionsAndRepliesNotificationsExceptions") as? [String: String]) ?? [:]
}
var sgHideAccountInNotifications: Bool {
    return groupUserDefaults?.bool(forKey: "hideAccountInNotifications") ?? false
}
//

