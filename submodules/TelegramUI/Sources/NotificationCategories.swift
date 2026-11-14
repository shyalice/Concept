import Foundation
import UserNotifications
import Intents
import TelegramCallsUI

func installConceptNotificationCategories(replyString: String, messagePlaceholderString: String, hiddenContentString: String, hiddenReactionContentString: String, hiddenStoryContentString: String, hiddenStoryReactionContentString: String, callUnlockVideoString: String, includeNames: Bool) {
    let reply = UNTextInputNotificationAction(identifier: "reply", title: replyString, options: [], textInputButtonTitle: replyString, textInputPlaceholder: messagePlaceholderString)

    let unknownMessageCategory: UNNotificationCategory
    let repliableMessageCategory: UNNotificationCategory
    let repliableMediaMessageCategory: UNNotificationCategory
    let groupRepliableMessageCategory: UNNotificationCategory
    let groupRepliableMediaMessageCategory: UNNotificationCategory
    let channelMessageCategory: UNNotificationCategory
    let reactionMessageCategory: UNNotificationCategory
    let storyCategory: UNNotificationCategory
    let storyReactionCategory: UNNotificationCategory

    var options: UNNotificationCategoryOptions = []
    if includeNames {
        options.insert(.hiddenPreviewsShowTitle)
    }

    var carPlayOptions = options
    carPlayOptions.insert(.allowInCarPlay)

    unknownMessageCategory = UNNotificationCategory(identifier: "unknown", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenContentString, options: options)
    repliableMessageCategory = UNNotificationCategory(identifier: "r", actions: [reply], intentIdentifiers: [INSearchForMessagesIntentIdentifier], hiddenPreviewsBodyPlaceholder: hiddenContentString, options: carPlayOptions)
    repliableMediaMessageCategory = UNNotificationCategory(identifier: "m", actions: [reply], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenContentString, options: carPlayOptions)
    groupRepliableMessageCategory = UNNotificationCategory(identifier: "gr", actions: [reply], intentIdentifiers: [INSearchForMessagesIntentIdentifier], hiddenPreviewsBodyPlaceholder: hiddenContentString, options: carPlayOptions)
    groupRepliableMediaMessageCategory = UNNotificationCategory(identifier: "gm", actions: [reply], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenContentString, options: carPlayOptions)
    channelMessageCategory = UNNotificationCategory(identifier: "c", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenContentString, options: options)
    reactionMessageCategory = UNNotificationCategory(identifier: "t", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenReactionContentString, options: options)
    storyCategory = UNNotificationCategory(identifier: "st", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenStoryContentString, options: options)
    storyReactionCategory = UNNotificationCategory(identifier: "str", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenStoryReactionContentString, options: options)
    // The unlock-video notification is read on the lock screen: its own text stands in while previews
    // are hidden.
    let callUnlockVideoCategory = UNNotificationCategory(identifier: CallUnlockVideoNotificationState.categoryIdentifier, actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: callUnlockVideoString, options: [])

    UNUserNotificationCenter.current().setNotificationCategories([
        unknownMessageCategory,
        repliableMessageCategory,
        repliableMediaMessageCategory,
        channelMessageCategory,
        reactionMessageCategory,
        groupRepliableMessageCategory,
        groupRepliableMediaMessageCategory,
        storyCategory,
        storyReactionCategory,
        callUnlockVideoCategory
    ])
}
