import SGAppGroupIdentifier // MARK: Swiftgram
import Foundation
import PasscodeCore
import UserNotifications
import SwiftSignalKit
import Postbox
import TelegramCore
import BuildConfig
import OpenSSLEncryptionProvider
import TelegramUIPreferences
import WebPBinding
import LottieBinding
import GZip
import UIKit
import Intents
import PersistentStringHash
import CallKit
import AppLockState
import NotificationsPresentationData
import RangeSet
import ConvertOpusToAAC
import CoreServices
import ImageIO
import UniformTypeIdentifiers

func getCurrentRenderedTotalUnreadCount(accountManager: AccountManager<TelegramAccountManagerTypes>, postbox: Postbox) -> Signal<(Int32, RenderedTotalUnreadCountType), NoError> {
    let counters = postbox.transaction { transaction -> ChatListTotalUnreadState in
        return transaction.getTotalUnreadState(groupId: .root)
    }
    return combineLatest(
        accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.inAppNotificationSettings])
        |> take(1),
        counters
    )
    |> map { sharedData, totalReadCounters -> (Int32, RenderedTotalUnreadCountType) in
        let inAppSettings: InAppNotificationSettings
        if let value = sharedData.entries[ApplicationSpecificSharedDataKeys.inAppNotificationSettings]?.get(InAppNotificationSettings.self) {
            inAppSettings = value
        } else {
            inAppSettings = .defaultSettings
        }
        let type: RenderedTotalUnreadCountType
        switch inAppSettings.totalUnreadCountDisplayStyle {
            case .filtered:
                type = .filtered
        }
        return (totalReadCounters.count(for: inAppSettings.totalUnreadCountDisplayStyle.category, in: inAppSettings.totalUnreadCountDisplayCategory.statsType, with: inAppSettings.totalUnreadCountIncludeTags), type)
    }
}

@available(iOSApplicationExtension 10.0, iOS 10.0, *)
final class NotificationServiceHandler {
    private let queue: Queue
    private let accountManager: AccountManager<TelegramAccountManagerTypes>
    private let encryptionParameters: ValueBoxEncryptionParameters
    private var stateManager: AccountStateManager?

    private let preparationDisposable = MetaDisposable()
    private let stateManagerDisposable = MetaDisposable()
    private let notificationKeyDisposable = MetaDisposable()
    private let pollDisposable = MetaDisposable()
    private let voiceConversionDisposable = MetaDisposable()
    // The budget starts at didReceive, before this handler or its queue can run.
    private let requestWork: NotificationRequestWork
    private let budget: NotificationExecutionBudget

    init?(queue: Queue, episode: String, requestWork: NotificationRequestWork, budget: NotificationExecutionBudget, updateCurrentContent: @escaping (NotificationContent) -> Void, completed: @escaping () -> Void, requestIdentifier: String, payload: [AnyHashable: Any]) {
        //debug_linker_fail_test()
        self.queue = queue
        self.requestWork = requestWork
        self.budget = budget
        let suppressContent = Atomic<Bool>(value: false)
        let deliverCurrentContent: (NotificationContent) -> Void = { incoming in
            guard !requestWork.isCancelled else { return }
            var content = incoming
            if suppressContent.with({ $0 }) {
                content.isEmpty = true
            }
            updateCurrentContent(content)
        }

        // In the extension, database BEGIN/COMMIT/step failures must crash (the system then
        // falls back to displaying the unmodified push) instead of failing silently: silent
        // failures under cross-process lock contention produce non-atomic writes and pin the
        // account state, turning the difference polling loop into an infinite livelock.
        setValueBoxStrictErrorHandling(true)

        guard let appBundleIdentifier = Bundle.main.bundleIdentifier, let lastDotRange = appBundleIdentifier.range(of: ".", options: [.backwards]) else {
            return nil
        }

        let baseAppBundleId = String(appBundleIdentifier[..<lastDotRange.lowerBound])
        let buildConfig = BuildConfig(baseAppBundleId: baseAppBundleId)

        let apiId: Int32 = buildConfig.apiId
        let apiHash: String = buildConfig.apiHash
        let languagesCategory = "ios"

        let appGroupName = sgAppGroupIdentifier()
        do {
            try PasscodeEnvironment.shared.configure(PasscodeConfiguration(appGroupIdentifier: appGroupName, processRole: .appExtension))
        } catch {
            return nil
        }
        let maybeAppGroupUrl = sgAppGroupContainerURL()
        if maybeAppGroupUrl != nil {
            AntiDeleteManager.shared.configureSharedDefaults(suiteName: appGroupName)
        }

        guard let appGroupUrl = maybeAppGroupUrl else {
            return nil
        }

        let rootPath = rootPathForBasePath(appGroupUrl.path)

        TempBox.initializeShared(basePath: rootPath, processType: "notification", launchSpecificId: Int64.random(in: Int64.min ... Int64.max))

        let logsPath = rootPath + "/logs/notification-logs"
        let _ = try? FileManager.default.createDirectory(atPath: logsPath, withIntermediateDirectories: true, attributes: nil)

        setupSharedLogger(rootPath: logsPath, path: logsPath)
        
        Logger.shared.log("NotificationService \(episode)", "Started handling notification")

        initializeAccountManagement()

        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"

        self.accountManager = setupAccountManager(basePath: rootPath + "/accounts-metadata", isTemporary: true, isReadOnly: false, useCaches: false, removeDatabaseOnError: false)

        let deviceSpecificEncryptionParameters = BuildConfig.deviceSpecificEncryptionParameters(rootPath, baseAppBundleId: baseAppBundleId)
        self.encryptionParameters = ValueBoxEncryptionParameters(forceEncryptionIfNoSet: false, key: ValueBoxEncryptionParameters.Key(data: deviceSpecificEncryptionParameters.key)!, salt: ValueBoxEncryptionParameters.Salt(data: deviceSpecificEncryptionParameters.salt)!)
        
        // Logging must not block the notification queue on a database semaphore.
        // Its persisted settings arrive with the account/settings snapshot below.
        let initialLoggingSettings = LoggingSettings.defaultSettings
        Logger.shared.logToFile = initialLoggingSettings.logToFile
        Logger.shared.logToConsole = initialLoggingSettings.logToConsole
        Logger.shared.redactSensitiveData = true

        let networkArguments = NetworkInitializationArguments(apiId: apiId, apiHash: apiHash, languagesCategory: languagesCategory, appVersion: appVersion, voipMaxLayer: 0, voipVersions: [], appData: .single(buildConfig.bundleData(withAppToken: nil, tokenType: nil, tokenEnvironment: nil, signatureDict: nil)), externalRequestVerificationStream: .never(), externalRecaptchaRequestVerification: { _, _ in return .never() }, autolockDeadine: .single(nil), encryptionProvider: OpenSSLEncryptionProvider(), deviceModelName: nil, useBetaFeatures: !buildConfig.isAppStoreBuild, isICloudEnabled: false)
        
        let isLockedMessage: String?
        let isLockedStoryMessage: String?
        if let data = try? Data(contentsOf: URL(fileURLWithPath: appLockStatePath(rootPath: rootPath))), let state = try? JSONDecoder().decode(LockState.self, from: data), isAppLocked(state: state) {
            if let notificationsPresentationData = try? Data(contentsOf: URL(fileURLWithPath: notificationsPresentationDataPath(rootPath: rootPath))), let notificationsPresentationDataValue = try? JSONDecoder().decode(NotificationsPresentationData.self, from: notificationsPresentationData) {
                isLockedMessage = notificationsPresentationDataValue.applicationLockedMessageString
                isLockedStoryMessage = notificationsPresentationDataValue.applicationLockedStoryString ?? notificationsPresentationDataValue.applicationLockedMessageString
            } else {
                isLockedMessage = "You have a new message"
                isLockedStoryMessage = "You have a new story"
            }
        } else {
            isLockedMessage = nil
            isLockedStoryMessage = nil
        }
        
        let incomingCallMessage: String
        if let notificationsPresentationData = try? Data(contentsOf: URL(fileURLWithPath: notificationsPresentationDataPath(rootPath: rootPath))), let notificationsPresentationDataValue = try? JSONDecoder().decode(NotificationsPresentationData.self, from: notificationsPresentationData) {
            incomingCallMessage = notificationsPresentationDataValue.incomingCallString
        } else {
            incomingCallMessage = "is calling you"
        }

        Logger.shared.log("NotificationService \(episode)", "Begin processing payload")

        guard var encryptedPayload = payload["p"] as? String else {
            Logger.shared.log("NotificationService \(episode)", "Invalid payload 1")
            return nil
        }
        encryptedPayload = encryptedPayload.replacingOccurrences(of: "-", with: "+")
        encryptedPayload = encryptedPayload.replacingOccurrences(of: "_", with: "/")
        while encryptedPayload.count % 4 != 0 {
            encryptedPayload.append("=")
        }
        guard let payloadData = Data(base64Encoded: encryptedPayload) else {
            Logger.shared.log("NotificationService \(episode)", "Invalid payload 2")
            return nil
        }

        self.preparationDisposable.set((combineLatest(queue: self.queue,
            self.accountManager.accountRecords(),
            self.accountManager.sharedData(keys: [
                ApplicationSpecificSharedDataKeys.inAppNotificationSettings,
                ApplicationSpecificSharedDataKeys.voiceCallSettings,
                ApplicationSpecificSharedDataKeys.automaticMediaDownloadSettings,
                SharedDataKeys.loggingSettings,
                ApplicationSpecificSharedDataKeys.sgStatus,
                SharedDataKeys.conceptSecretPasscodes
            ])
        )
        |> take(1)
        |> deliverOn(self.queue)).start(request: requestWork, next: { [weak self] records, sharedData in
            let loggingSettings = sharedData.entries[SharedDataKeys.loggingSettings]?.get(LoggingSettings.self) ?? initialLoggingSettings
            Logger.shared.logToFile = loggingSettings.logToFile
            Logger.shared.logToConsole = loggingSettings.logToConsole
            Logger.shared.redactSensitiveData = loggingSettings.redactSensitiveData

            var recordId: AccountRecordId?
            var isCurrentAccount: Bool = false
            
//            var automaticMediaDownloadSettings: MediaAutoDownloadSettings
//            if let value = sharedData.entries[ApplicationSpecificSharedDataKeys.automaticMediaDownloadSettings]?.get(MediaAutoDownloadSettings.self) {
//                automaticMediaDownloadSettings = value
//            } else {
//                automaticMediaDownloadSettings = MediaAutoDownloadSettings.defaultSettings
//            }
            let shouldSynchronizeState = true//automaticMediaDownloadSettings.energyUsageSettings.synchronizeInBackground

            if let keyId = notificationPayloadKeyId(data: payloadData) {
                outer: for listRecord in records.records {
                    for attribute in listRecord.attributes {
                        if case let .backupData(backupData) = attribute {
                            if let notificationEncryptionKeyId = backupData.data?.notificationEncryptionKeyId {
                                if keyId == notificationEncryptionKeyId {
                                    recordId = listRecord.id
                                    isCurrentAccount = records.currentRecord?.id == listRecord.id
                                    break outer
                                }
                            }
                        }
                    }
                }
            }

            let inAppNotificationSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.inAppNotificationSettings]?.get(InAppNotificationSettings.self) ?? InAppNotificationSettings.defaultSettings
            let sgStatus = sharedData.entries[ApplicationSpecificSharedDataKeys.sgStatus]?.get(SGStatus.self) ?? SGStatus.default // MARK: Swiftgram
            
            let voiceCallSettings: VoiceCallSettings
            if let value = sharedData.entries[ApplicationSpecificSharedDataKeys.voiceCallSettings]?.get(VoiceCallSettings.self) {
                voiceCallSettings = value
            } else {
                voiceCallSettings = VoiceCallSettings.defaultSettings
            }

            guard let strongSelf = self, let recordId = recordId else {
                Logger.shared.log("NotificationService \(episode)", "Couldn't find a matching decryption key")

                let content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil) // MARK: Swiftgram
                deliverCurrentContent(content)
                completed()

                return
            }

            let conceptSecretPasscodes = sharedData.entries[SharedDataKeys.conceptSecretPasscodes]?.get(ConceptSecretPasscodes.self) ?? ConceptSecretPasscodes.defaultSettings
            let checkedSecretPasscodes = conceptSecretPasscodes.withCheckedTimeoutUsingLockStateFile(rootPath: rootPath)
            let isHiddenAccount = checkedSecretPasscodes.inactiveAccountIds().contains(recordId)
            if isHiddenAccount {
                _ = suppressContent.swap(true)
                deliverCurrentContent(NotificationContent(sgStatus: sgStatus, isLockedMessage: nil, isEmpty: true))
            }

            strongSelf.stateManagerDisposable.set((standaloneStateManager(
                accountManager: strongSelf.accountManager,
                networkArguments: networkArguments,
                id: recordId,
                encryptionParameters: strongSelf.encryptionParameters,
                rootPath: rootPath,
                auxiliaryMethods: accountAuxiliaryMethods,
                initialPeerIdsExcludedFromUnreadCounters: checkedSecretPasscodes.inactiveSecretChatPeerIds(accountId: recordId)
            )
            |> deliverOn(strongSelf.queue)).start(request: requestWork, next: { stateManager in
                guard let strongSelf = self else {
                    return
                }
                guard let stateManager = stateManager else {
                    Logger.shared.log("NotificationService \(episode)", "Didn't receive stateManager")

                    let content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil) // MARK: Swiftgram
                    deliverCurrentContent(content)
                    completed()
                    return
                }
                strongSelf.stateManager = stateManager
                requestWork.addCancellation { stateManager.network.shouldKeepConnection.set(.single(false)) }
                
                let accountPeerId = stateManager.accountPeerId
                
                let settings = stateManager.postbox.transaction { transaction -> NotificationSoundList? in
                    return _internal_cachedNotificationSoundList(transaction: transaction)
                }

                // Read up front so that the first content handed over, the one shown if the
                // extension runs out of time, already names the account. Only when it is named:
                // every transaction here takes the database write lock the app may hold.
                let recipientAccountName: Signal<String?, NoError>
                if notificationsNameRecipientAccount(records: records.records, notificationsFromAllAccounts: inAppNotificationSettings.displayNotificationsFromAllAccounts, isCurrentAccount: isCurrentAccount) && !sgHideAccountInNotifications { // MARK: Swiftgram
                    recipientAccountName = stateManager.postbox.transaction { transaction -> String? in
                        return notificationRecipientAccountName(accountPeer: transaction.getPeer(accountPeerId).flatMap(EnginePeer.init))
                    }
                } else {
                    recipientAccountName = .single(nil)
                }

                strongSelf.notificationKeyDisposable.set((combineLatest(queue: strongSelf.queue,
                    existingMasterNotificationsKey(postbox: stateManager.postbox),
                    settings,
                    recipientAccountName
                ) |> take(1) |> deliverOn(strongSelf.queue)).start(request: requestWork, next: { notificationsKey, notificationSoundList, recipientAccountName in
                    guard let strongSelf = self else {
                        let content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil) // MARK: Swiftgram
                        deliverCurrentContent(content)
                        completed()

                        return
                    }
                    guard let notificationsKey = notificationsKey else {
                        Logger.shared.log("NotificationService \(episode)", "Didn't receive decryption key")

                        let content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil) // MARK: Swiftgram
                        deliverCurrentContent(content)
                        completed()

                        return
                    }
                    guard let decryptedPayload = decryptedNotificationPayload(key: notificationsKey, data: payloadData) else {
                        Logger.shared.log("NotificationService \(episode)", "Couldn't decrypt payload")

                        let content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil) // MARK: Swiftgram
                        deliverCurrentContent(content)
                        completed()

                        return
                    }
                    guard let payloadJson = try? JSONSerialization.jsonObject(with: decryptedPayload, options: []) as? [String: Any] else {
                        Logger.shared.log("NotificationService \(episode)", "Couldn't process payload as JSON")

                        let content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil) // MARK: Swiftgram
                        deliverCurrentContent(content)
                        completed()

                        return
                    }
                    // MARK: Swiftgram
                    let isMentionOrReply: Bool = payloadJson["mention"] as? String == "1"
                    var chatId: Int64? = nil
                    if let chatIdString = payloadJson["chat_id"] as? String {
                        chatId = Int64(chatIdString)
                    } else if let channelIdString = payloadJson["channel_id"] as? String {
                        chatId = Int64(channelIdString)
                    }
                    //

                    var peerId: PeerId?
                    var messageId: MessageId.Id?
                    var storyId: Int32?
                    var mediaAttachment: Media?
                    // Commits the notification → message link Siri's announce flow looks up;
                    // the poll path runs it ahead of the fetch so the content is handed to the
                    // system only after the link is stored.
                    var recordNotificationLink: Signal<Never, NoError> = .complete()
                    var downloadNotificationSound: (file: TelegramMediaFile, path: String, fileName: String)?

                    var interactionAuthorId: PeerId?
                    var topicTitle: String?

                    struct CallData {
                        var id: Int64
                        var accessHash: Int64
                        var fromId: PeerId
                        var updates: String
                        var accountId: Int64
                        var peer: EnginePeer?
                        var localContactId: String?
                    }
                    
                    struct GroupCallData {
                        var id: Int64
                        var fromId: PeerId
                        var fromTitle: String
                        var memberCount: Int
                        var isVideo: Bool
                        var messageId: Int32
                        var accountId: Int64
                    }

                    var callData: CallData?
                    var groupCallData: GroupCallData?

                    if let messageIdString = payloadJson["msg_id"] as? String {
                        messageId = Int32(messageIdString)
                    }
                    if let storyIdString = payloadJson["story_id"] as? String {
                        storyId = Int32(storyIdString)
                    }

                    var authorUserId: PeerId?
                    if let fromIdString = payloadJson["from_id"] as? String {
                        if let userIdValue = Int64(fromIdString) {
                            authorUserId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(userIdValue))
                        }
                    }

                    if let chatIdString = payloadJson["chat_id"] as? String {
                        if let chatIdValue = Int64(chatIdString) {
                            peerId = PeerId(namespace: Namespaces.Peer.CloudGroup, id: PeerId.Id._internalFromInt64Value(chatIdValue))
                        }
                    } else if let channelIdString = payloadJson["channel_id"] as? String {
                        if let channelIdValue = Int64(channelIdString) {
                            peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(channelIdValue))
                        }
                    } else if let authorUserId = authorUserId {
                        peerId = authorUserId
                    } else if let encryptionIdString = payloadJson["encryption_id"] as? String {
                        if let encryptionIdValue = Int64(encryptionIdString) {
                            peerId = PeerId(namespace: Namespaces.Peer.SecretChat, id: PeerId.Id._internalFromInt64Value(encryptionIdValue))
                        }
                    }
                    
                    if isHiddenAccount || peerId.map({ checkedSecretPasscodes.inactiveSecretChatPeerIds(accountId: recordId).contains($0) }) == true {
                        _ = suppressContent.swap(true)
                        deliverCurrentContent(NotificationContent(sgStatus: sgStatus, isLockedMessage: nil, isEmpty: true))
                        // Calls use CallKit rather than notification content. They
                        // must not announce a hidden chat, while ordinary message
                        // pushes can still synchronize and retain their content.
                        if payloadJson["call_id"] != nil || ["CONF_CALL_REQUEST", "CONF_CALL_INVITE"].contains(payloadJson["loc-key"] as? String ?? "") {
                            completed()
                            return
                        }
                    }

                    #if DEBUG
                    if let locKey = payloadJson["loc-key"] as? String, locKey == "CONF_CALL_REQUEST" {
                    }
                    #endif

                    if let peerId, let locKey = payloadJson["loc-key"] as? String, (locKey == "CONF_CALL_REQUEST" || locKey == "CONF_VIDEOCALL_REQUEST"), let callIdString = payloadJson["call_id"] as? String, let messageIdString = payloadJson["msg_id"] as? String {
                        if let callId = Int64(callIdString), let messageId = Int32(messageIdString) {
                            if let fromTitle = payloadJson["call_conference_from"] as? String {
                                let isVideo = locKey == "CONF_VIDEOCALL_REQUEST"
                                var memberCount = 0
                                if let callParticipantsCountString = payloadJson["call_participants_cnt"] as? String, let callParticipantsCount = Int(callParticipantsCountString) {
                                    memberCount = callParticipantsCount
                                }
                                
                                groupCallData = GroupCallData(
                                    id: callId,
                                    fromId: peerId,
                                    fromTitle: fromTitle,
                                    memberCount: memberCount,
                                    isVideo: isVideo,
                                    messageId: messageId,
                                    accountId: recordId.int64
                                )
                            }
                        }
                    } else if let callIdString = payloadJson["call_id"] as? String, let callAccessHashString = payloadJson["call_ah"] as? String, let peerId = peerId, let updates = payloadJson["updates"] as? String {
                        if let callId = Int64(callIdString), let callAccessHash = Int64(callAccessHashString) {
                            var peer: EnginePeer?
                            
                            var updateString = updates
                            updateString = updateString.replacingOccurrences(of: "-", with: "+")
                            updateString = updateString.replacingOccurrences(of: "_", with: "/")
                            while updateString.count % 4 != 0 {
                                updateString.append("=")
                            }
                            if let updateData = Data(base64Encoded: updateString) {
                                if let callUpdate = AccountStateManager.extractIncomingCallUpdate(data: updateData) {
                                    peer = callUpdate.peer
                                }
                            }
                            
                            callData = CallData(
                                id: callId,
                                accessHash: callAccessHash,
                                fromId: peerId,
                                updates: updates,
                                accountId: recordId.int64,
                                peer: peer
                            )
                        }
                    }

                    enum Action {
                        case logout
                        case poll(peerId: PeerId, content: NotificationContent, messageId: MessageId?, reportDelivery: Bool, enableInlineEmoji: Bool)
                        case pollStories(peerId: PeerId, content: NotificationContent, storyId: Int32, isReaction: Bool)
                        case deleteMessage([MessageId])
                        case readReactions([MessageId])
                        case readMessage(MessageId)
                        case readStories(peerId: PeerId, maxId: Int32)
                        case call(CallData)
                        case groupCall(GroupCallData)
                    }

                    var action: Action?

                    if let callData = callData {
                        action = .call(callData)
                    } else if let groupCallData {
                        action = .groupCall(groupCallData)
                    } else if let locKey = payloadJson["loc-key"] as? String {
                        switch locKey {
                        case "SESSION_REVOKE":
                            action = .logout
                        case "MESSAGE_MUTED":
                            if let peerId = peerId {
                                action = .poll(peerId: peerId, content: NotificationContent(sgStatus: sgStatus, isLockedMessage: nil, isEmpty: true, isMentionOrReply: isMentionOrReply, chatId: chatId), messageId: nil, reportDelivery: false, enableInlineEmoji: false) // MARK: Swiftgram
                            }
                        case "MESSAGE_DELETED":
                            if let peerId = peerId {
                                if let messageId = messageId {
                                    action = .deleteMessage([MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: messageId)])
                                } else if let messageIds = payloadJson["messages"] as? String {
                                    var messagesDeleted: [MessageId] = []
                                    for messageId in messageIds.split(separator: ",") {
                                        if let messageIdValue = Int32(messageId) {
                                            messagesDeleted.append(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: messageIdValue))
                                        }
                                    }
                                    action = .deleteMessage(messagesDeleted)
                                }
                            }
                        case "READ_REACTION":
                            if let peerId {
                                if let messageId = messageId {
                                    action = .readReactions([MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: messageId)])
                                } else if let messageIds = payloadJson["messages"] as? String {
                                    var messages: [MessageId] = []
                                    for messageId in messageIds.split(separator: ",") {
                                        if let messageIdValue = Int32(messageId) {
                                            messages.append(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: messageIdValue))
                                        }
                                    }
                                    action = .readReactions(messages)
                                }
                            }
                        case "READ_HISTORY":
                            if let peerId = peerId {
                                if let messageIdString = payloadJson["max_id"] as? String {
                                    if let maxId = Int32(messageIdString) {
                                        action = .readMessage(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: maxId))
                                    }
                                }
                            }
                        case "READ_STORIES":
                            if let peerId = peerId {
                                if let storyIdString = payloadJson["max_id"] as? String {
                                    if let maxId = Int32(storyIdString) {
                                        action = .readStories(peerId: peerId, maxId: maxId)
                                    }
                                }
                            }
                        default:
                            break
                        }
                    } else {
                        if let aps = payloadJson["aps"] as? [String: Any], var peerId = peerId {
                            var content: NotificationContent = NotificationContent(sgStatus: sgStatus, isLockedMessage: isLockedMessage, isMentionOrReply: isMentionOrReply, chatId: chatId) // MARK: Swiftgram
                            content.recipientAccountName = recipientAccountName
                            if let alert = aps["alert"] as? [String: Any] {
                                if let topicTitleValue = payloadJson["topic_title"] as? String {
                                    topicTitle = topicTitleValue
                                    if let title = alert["title"] as? String {
                                        content.title = "\(topicTitleValue) (\(title))"
                                    } else {
                                        content.title = topicTitleValue
                                    }
                                } else {
                                    content.title = alert["title"] as? String
                                }
                                content.subtitle = alert["subtitle"] as? String
                                content.body = alert["body"] as? String
                            } else if let alert = aps["alert"] as? String {
                                content.body = alert
                            } else {
                                completed()
                                return
                            }

                            var messageIdValue: MessageId?
                            if let messageId = messageId {
                                content.userInfo["msg_id"] = "\(messageId)"
                                interactionAuthorId = authorUserId ?? peerId
                                
                                messageIdValue = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: messageId)
                            }
                            
                            var isReaction = false
                            if let category = aps["category"] as? String {
                                if peerId.isGroupOrChannel && ["r", "m"].contains(category) {
                                    content.category = "g\(category)"
                                } else {
                                    content.category = category
                                }
                                
                                if aps["r"] != nil || aps["react_emoji"] != nil {
                                    isReaction = true
                                    content.category = "t"
                                } else if payloadJson["r"] != nil || payloadJson["react_emoji"] != nil {
                                    isReaction = true
                                    content.category = "t"
                                }
                                
                                if category == "str" {
                                    isReaction = true
                                }

                                let _ = messageId
                            }
                            
                            if let storyId = storyId {
                                interactionAuthorId = peerId
                                if isReaction {
                                    peerId = accountPeerId
                                }
                                content.userInfo["story_id"] = "\(storyId)"
                            }

                            if peerId.namespace == Namespaces.Peer.CloudUser {
                                content.userInfo["from_id"] = "\(peerId.id._internalGetInt64Value())"
                            } else if peerId.namespace == Namespaces.Peer.CloudGroup {
                                content.userInfo["chat_id"] = "\(peerId.id._internalGetInt64Value())"
                            } else if peerId.namespace == Namespaces.Peer.CloudChannel {
                                content.userInfo["channel_id"] = "\(peerId.id._internalGetInt64Value())"
                            }

                            content.userInfo["peerId"] = "\(peerId.toInt64())"
                            content.userInfo["accountId"] = "\(recordId.int64)"
                            
                            if let silentString = payloadJson["silent"] as? String {
                                if let silentValue = Int(silentString), silentValue != 0 {
                                    content.silent = true
                                }
                            }
                            if var attachmentDataString = payloadJson["attachb64"] as? String {
                                attachmentDataString = attachmentDataString.replacingOccurrences(of: "-", with: "+")
                                attachmentDataString = attachmentDataString.replacingOccurrences(of: "_", with: "/")
                                while attachmentDataString.count % 4 != 0 {
                                    attachmentDataString.append("=")
                                }
                                if let attachmentData = Data(base64Encoded: attachmentDataString) {
                                    mediaAttachment = _internal_parseMediaAttachment(data: attachmentData)
                                }
                            }

                            if let threadId = aps["thread-id"] as? String {
                                content.threadId = threadId
                            }
                            if let topicIdValue = payloadJson["topic_id"] as? String, let topicId = Int(topicIdValue) {
                                if let threadId = content.threadId {
                                    content.threadId = "\(threadId):\(topicId)"
                                }
                                content.userInfo["threadId"] = Int32(clamping: topicId)
                            }

                            if let ringtoneString = aps["ringtone"] as? String, let fileId = Int64(ringtoneString) {
                                content.sound = "0.m4a"
                                if let notificationSoundList = notificationSoundList {
                                    for sound in notificationSoundList.sounds {
                                        if sound.file.fileId.id == fileId {
                                            let containerSoundsPath = appGroupUrl.path + "/Library/Sounds"
                                            let soundFileName = "\(fileId).mp3"
                                            let soundFilePath = containerSoundsPath + "/\(soundFileName)"
                                            
                                            if !FileManager.default.fileExists(atPath: soundFilePath) {
                                                let _ = try? FileManager.default.createDirectory(atPath: containerSoundsPath, withIntermediateDirectories: true, attributes: nil)
                                                if let filePath = stateManager.postbox.mediaBox.completedResourcePath(id: sound.file.resource.id, pathExtension: nil) {
                                                    let _ = try? FileManager.default.copyItem(atPath: filePath, toPath: soundFilePath)
                                                } else {
                                                    downloadNotificationSound = (sound.file, soundFilePath, soundFileName)
                                                }
                                            }
                                            
                                            content.sound = soundFileName
                                            break
                                        }
                                    }
                                }
                            } else if let sound = aps["sound"] as? String {
                                content.sound = sound
                            }

                            if let storyId {
                                if isReaction {
                                    content.category = "str"
                                } else {
                                    content.category = "st"
                                    content.isLockedMessage = isLockedStoryMessage
                                }
                                
                                action = .pollStories(peerId: peerId, content: content, storyId: storyId, isReaction: isReaction)
                            } else {
                                var reportDelivery = false
                                if let reportDeliveryUntilDate = aps["report_delivery_until_date"] as? String, let reportDeliveryUntilDateValue = Int32(reportDeliveryUntilDate) {
                                    let currentTime = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
                                    if reportDeliveryUntilDateValue > currentTime {
                                        reportDelivery = true
                                    }
                                }
                                var enableInlineEmoji = true
                                if let _ = aps["_ddie"] {
                                    enableInlineEmoji = false
                                }
                                action = .poll(peerId: peerId, content: content, messageId: messageIdValue, reportDelivery: reportDelivery, enableInlineEmoji: enableInlineEmoji)

                                // Siri's announce flow asks the intents extension for the message
                                // behind a delivered notification by the request identifier the
                                // system assigned to it. That identifier exists only here. Reactions
                                // are left out: their category never routes through the search
                                // intent, and the link would read the reacted-to message as new.
                                if let messageIdValue, !isReaction {
                                    let previewText = content.body ?? ""
                                    let previewReceivedAt = Int32(clamping: Int64(Date().timeIntervalSince1970))
                                    recordNotificationLink = stateManager.postbox.transaction { transaction -> Void in
                                        _internal_setNotificationRequestMessageId(transaction: transaction, requestIdentifier: requestIdentifier, messageId: messageIdValue)
                                        _internal_conceptStoreNotificationPreview(transaction: transaction, id: messageIdValue, text: previewText, receivedAt: previewReceivedAt)
                                    }
                                    |> ignoreValues
                                }
                            }

                            deliverCurrentContent(content)
                        } else if let aps = payloadJson["aps"] as? [String: Any], let url = payloadJson["url"] as? String {
                            var content: NotificationContent = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil) // MARK: Swiftgram
                            content.recipientAccountName = recipientAccountName
                            content.userInfo["url"] = url
                            content.userInfo["peerId"] = "777000"
                            content.userInfo["accountId"] = "\(recordId.int64)"
                            if let sound = aps["sound"] as? String {
                                content.sound = sound
                            }
                            if let alert = aps["alert"] as? [String: Any] {
                                if let topicTitleValue = payloadJson["topic_title"] as? String {
                                    topicTitle = topicTitleValue
                                    if let title = alert["title"] as? String {
                                        content.title = "\(topicTitleValue) (\(title))"
                                    } else {
                                        content.title = topicTitleValue
                                    }
                                } else {
                                    content.title = alert["title"] as? String
                                }
                                content.subtitle = alert["subtitle"] as? String
                                content.body = alert["body"] as? String
                            } else if let alert = aps["alert"] as? String {
                                content.body = alert
                            } else {
                                content.body = "You have a new message"
                            }
                            deliverCurrentContent(content)
                            completed()
                            return
                        }
                    }

                    if let action = action {
                        switch action {
                        case .logout, .deleteMessage, .readReactions, .readMessage, .readStories:
                            deliverCurrentContent(NotificationContent(sgStatus: sgStatus, isLockedMessage: nil, isEmpty: true))
                        default:
                            break
                        }
                        switch action {
                        case let .call(callData):
                            if let stateManager = strongSelf.stateManager {
                                let content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil) // MARK: Swiftgram
                                deliverCurrentContent(content)
                                
                                let _ = (stateManager.postbox.transaction { transaction -> String? in
                                    if let peer = transaction.getPeer(callData.fromId) as? TelegramUser {
                                        return peer.phone
                                    } else {
                                        return nil
                                    }
                                }).start(request: requestWork, next: { phoneNumber in
                                    var voipPayload: [AnyHashable: Any] = [
                                        "call_id": "\(callData.id)",
                                        "call_ah": "\(callData.accessHash)",
                                        "from_id": "\(callData.fromId.id._internalGetInt64Value())",
                                        "updates": callData.updates,
                                        "accountId": "\(callData.accountId)"
                                    ]
                                    if let phoneNumber = phoneNumber {
                                        voipPayload["phoneNumber"] = phoneNumber
                                    }

                                    if #available(iOS 14.5, *), voiceCallSettings.enableSystemIntegration {
                                        Logger.shared.log("NotificationService \(episode)", "Will report voip notification")
                                        let content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil) // MARK: Swiftgram
                                        deliverCurrentContent(content)
                                        
                                        CXProvider.reportNewIncomingVoIPPushPayload(voipPayload, completion: { error in
                                            Logger.shared.log("NotificationService \(episode)", "Did report voip notification, error: \(String(describing: error))")

                                            completed()
                                        })
                                    } else {
                                        var content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil) // MARK: Swiftgram
                                        content.recipientAccountName = recipientAccountName
                                        if let peer = callData.peer {
                                            content.title = peer.debugDisplayTitle
                                            content.body = incomingCallMessage
                                        } else {
                                            content.body = "Incoming Call"
                                        }
                                        
                                        deliverCurrentContent(content)
                                        completed()
                                    }
                                })
                            }
                        case let .groupCall(groupCallData):
                            if let stateManager = strongSelf.stateManager {
                                let content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil) // MARK: Swiftgram
                                deliverCurrentContent(content)
                                
                                let _ = (stateManager.postbox.transaction { transaction -> TelegramUser? in
                                    return transaction.getPeer(groupCallData.fromId) as? TelegramUser
                                }).start(request: requestWork, next: { fromPeer in
                                    var voipPayload: [AnyHashable: Any] = [
                                        "group_call_id": "\(groupCallData.id)",
                                        "msg_id": "\(groupCallData.messageId)",
                                        "video": "\(groupCallData.isVideo ? 1 : 0)",
                                        "member_count": "\(groupCallData.memberCount)",
                                        "from_id": "\(groupCallData.fromId.id._internalGetInt64Value())",
                                        "from_title": groupCallData.fromTitle,
                                        "accountId": "\(groupCallData.accountId)"
                                    ]
                                    if let phoneNumber = fromPeer?.phone {
                                        voipPayload["phoneNumber"] = phoneNumber
                                    }

                                    if #available(iOS 14.5, *), voiceCallSettings.enableSystemIntegration {
                                        Logger.shared.log("NotificationService \(episode)", "Will report voip notification")
                                        let content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil) // MARK: Swiftgram
                                        deliverCurrentContent(content)
                                        
                                        CXProvider.reportNewIncomingVoIPPushPayload(voipPayload, completion: { error in
                                            Logger.shared.log("NotificationService \(episode)", "Did report voip notification, error: \(String(describing: error))")

                                            completed()
                                        })
                                    } else {
                                        var content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil) // MARK: Swiftgram
                                        content.recipientAccountName = recipientAccountName
                                        if let peer = fromPeer {
                                            content.title = peer.debugDisplayTitle
                                            content.body = incomingCallMessage
                                        } else {
                                            content.body = "Incoming Call"
                                        }
                                        
                                        deliverCurrentContent(content)
                                        completed()
                                    }
                                })
                            }
                        case .logout:
                            Logger.shared.log("NotificationService \(episode)", "Will logout")

                            let content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil, isEmpty: true) // MARK: Swiftgram
                            deliverCurrentContent(content)
                            completed()
                        case let .poll(peerId, initialContent, messageId, reportDelivery, enableInlineEmoji):
                            Logger.shared.log("NotificationService \(episode)", "Will poll")
                            if let stateManager = strongSelf.stateManager {
                                let shouldKeepConnection = stateManager.network.shouldKeepConnection

                                // iOS expires the extension about 30 s after didReceive. Everything on
                                // this path that needs the connection is cut off at one deadline counted
                                // from handler creation, leaving slack for the postbox-only work after the
                                // fetches (unread count, content generation), so a slow poll cannot push
                                // the fetch step past expiry. The poll additionally has its own 15 s cap:
                                // without one, a push arriving while no connection can be established (a
                                // dead proxy, a blocked network) kept polling until the system expired the
                                // extension, and every retry along the way was a fresh connection attempt
                                // (bugs.telegram.org/c/64534, /c/61583). Giving up shows the payload's own
                                // text instead of the fetched message, which is the same content the
                                // expiry path would have shown, only sooner and without the retries.
                                let remainingBudget: () -> Double = {
                                    return budget.remaining()
                                }
                                let pollBudget: Double = 15.0
                                let pollCompleted = Atomic<Bool>(value: false)
                                let connectionGaveUp = Atomic<Bool>(value: false)

                                let pollCompletion: (NotificationContent, Media?) -> Void = { content, customMedia in
                                    var content = content

                                    // MARK: Swiftgram
                                    if let mediaAction = customMedia as? TelegramMediaAction, case .pinnedMessageUpdated = mediaAction.action {
                                        content.isPinned = true
                                    }
                                    //
                                    
                                    queue.async {
                                        guard let strongSelf = self, let stateManager = strongSelf.stateManager else {
                                            let content = NotificationContent(sgStatus: sgStatus, isLockedMessage: isLockedMessage) // MARK: Swiftgram
                                            deliverCurrentContent(content)
                                            completed()
                                            return
                                        }
                                        
                                        let mediaAttachment = mediaAttachment ?? customMedia

                                        var fetchMediaSignal: Signal<Data?, NoError> = .single(nil)
                                        if let mediaAttachment {
                                            var contentType: MediaResourceUserContentType = .other
                                            var fetchResource: TelegramMultipartFetchableResource?
                                            if let image = mediaAttachment as? TelegramMediaImage, let representation = largestImageRepresentation(image.representations), let resource = representation.resource as? TelegramMultipartFetchableResource {
                                                fetchResource = resource
                                                contentType = .image
                                            } else if let file = mediaAttachment as? TelegramMediaFile {
                                                if file.isSticker {
                                                    fetchResource = file.resource as? TelegramMultipartFetchableResource
                                                    contentType = .other
                                                } else if file.isVideo {
                                                    fetchResource = file.previewRepresentations.first?.resource as? TelegramMultipartFetchableResource
                                                    contentType = .video
                                                } else if file.isVoice {
                                                    fetchResource = file.resource as? TelegramMultipartFetchableResource
                                                    contentType = .audio
                                                } else {
                                                    contentType = .file
                                                }
                                            }

                                            if let resource = fetchResource {
                                                if let _ = strongSelf.stateManager?.postbox.mediaBox.completedResourcePath(resource) {
                                                } else {
                                                    let intervals: Signal<[(Range<Int64>, MediaBoxFetchPriority)], NoError> = .single([(0 ..< Int64.max, MediaBoxFetchPriority.maximum)])
                                                    fetchMediaSignal = Signal { subscriber in
                                                        final class DataValue {
                                                            var data = Data()
                                                            var missingRanges = RangeSet<Int64>(0 ..< Int64.max)
                                                        }
                                                        
                                                        let collectedData = Atomic<DataValue>(value: DataValue())
                                                        
                                                        return standaloneMultipartFetch(
                                                            accountPeerId: stateManager.accountPeerId,
                                                            postbox: stateManager.postbox,
                                                            network: stateManager.network,
                                                            resource: resource,
                                                            datacenterId: resource.datacenterId,
                                                            size: nil,
                                                            intervals: intervals,
                                                            parameters: MediaResourceFetchParameters(
                                                                tag: nil,
                                                                info: resourceFetchInfo(resource: resource),
                                                                location: messageId.flatMap { messageId in
                                                                    return MediaResourceStorageLocation(
                                                                        peerId: peerId,
                                                                        messageId: messageId
                                                                    )
                                                                },
                                                                contentType: contentType,
                                                                isRandomAccessAllowed: true
                                                            ),
                                                            encryptionKey: nil,
                                                            decryptedSize: nil,
                                                            continueInBackground: false,
                                                            useMainConnection: true
                                                        ).start(request: requestWork, next: { result in
                                                            switch result {
                                                            case let .dataPart(offset, data, dataRange, _):
                                                                var isCompleted = false
                                                                let _ = collectedData.modify { current in
                                                                    let current = current
                                                                    
                                                                    let fillRange = Int(offset) ..< (Int(offset) + data.count)
                                                                    if current.data.count < fillRange.upperBound {
                                                                        current.data.count = fillRange.upperBound
                                                                    }
                                                                    current.data.withUnsafeMutableBytes { buffer -> Void in
                                                                        let bytes = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                                                                        data.copyBytes(to: bytes.advanced(by: Int(offset)), from: Int(dataRange.lowerBound) ..< Int(dataRange.upperBound))
                                                                    }
                                                                    current.missingRanges.remove(contentsOf: Int64(fillRange.lowerBound) ..< Int64(fillRange.upperBound))
                                                                    
                                                                    if current.missingRanges.isEmpty {
                                                                        isCompleted = true
                                                                    }
                                                                    return current
                                                                }
                                                                if isCompleted {
                                                                    subscriber.putNext(collectedData.with({ $0.data }))
                                                                    subscriber.putCompletion()
                                                                }
                                                            case let .resourceSizeUpdated(size):
                                                                var isCompleted = false
                                                                let _ = collectedData.modify { current in
                                                                    let current = current
                                                                    current.missingRanges.remove(contentsOf: size ..< Int64.max)
                                                                    if current.missingRanges.isEmpty {
                                                                        isCompleted = true
                                                                    }
                                                                    return current
                                                                }
                                                                if isCompleted {
                                                                    subscriber.putNext(collectedData.with({ $0.data }))
                                                                    subscriber.putCompletion()
                                                                }
                                                            default:
                                                                break
                                                            }
                                                        }, error: { _ in
                                                            subscriber.putNext(nil)
                                                            subscriber.putCompletion()
                                                        }, completed: {
                                                            subscriber.putNext(collectedData.with({ $0.data }))
                                                            subscriber.putCompletion()
                                                        })
                                                    }
                                                }
                                            }
                                        }
                                        
                                        var fetchNotificationSoundSignal: Signal<Data?, NoError> = .single(nil)
                                        if let (downloadNotificationSound, _, _) = downloadNotificationSound {
                                            var fetchResource: TelegramMultipartFetchableResource?
                                            fetchResource = downloadNotificationSound.resource as? TelegramMultipartFetchableResource

                                            if let resource = fetchResource {
                                                if let path = strongSelf.stateManager?.postbox.mediaBox.completedResourcePath(resource), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                                                    fetchNotificationSoundSignal = .single(data)
                                                } else {
                                                    let intervals: Signal<[(Range<Int64>, MediaBoxFetchPriority)], NoError> = .single([(0 ..< Int64.max, MediaBoxFetchPriority.maximum)])
                                                    fetchNotificationSoundSignal = Signal { subscriber in
                                                        let collectedData = Atomic<Data>(value: Data())
                                                        return standaloneMultipartFetch(
                                                            accountPeerId: stateManager.accountPeerId,
                                                            postbox: stateManager.postbox,
                                                            network: stateManager.network,
                                                            resource: resource,
                                                            datacenterId: resource.datacenterId,
                                                            size: nil,
                                                            intervals: intervals,
                                                            parameters: MediaResourceFetchParameters(
                                                                tag: nil,
                                                                info: resourceFetchInfo(resource: resource),
                                                                location: nil,
                                                                contentType: .other,
                                                                isRandomAccessAllowed: true
                                                            ),
                                                            encryptionKey: nil,
                                                            decryptedSize: nil,
                                                            continueInBackground: false,
                                                            useMainConnection: true
                                                        ).start(request: requestWork, next: { result in
                                                            switch result {
                                                            case let .dataPart(_, data, _, _):
                                                                let _ = collectedData.modify { current in
                                                                    var current = current
                                                                    current.append(data)
                                                                    return current
                                                                }
                                                            default:
                                                                break
                                                            }
                                                        }, error: { _ in
                                                            subscriber.putNext(nil)
                                                            subscriber.putCompletion()
                                                        }, completed: {
                                                            subscriber.putNext(collectedData.with({ $0 }))
                                                            subscriber.putCompletion()
                                                        })
                                                    }
                                                }
                                            }
                                        }
                                        
                                        let wasDisplayed = stateManager.postbox.transaction { transaction -> Bool in
                                            var wasDisplayed = false
                                            if let messageId {
                                                wasDisplayed = _internal_getMessageNotificationWasDisplayed(transaction: transaction, id: messageId)
                                                if ConceptMessageFilterSettings.hideBlockedUsers,
                                                   let authorId = transaction.getMessage(messageId)?.author?.id ?? authorUserId,
                                                   let cached = transaction.getPeerCachedData(peerId: authorId) as? CachedUserData, cached.isBlocked {
                                                    wasDisplayed = true
                                                }
                                            }
                                            
                                            return wasDisplayed
                                        }
                                        
                                        let maxEmojiCount: Int = 10
                                        var uniqueEmojiIds: [Int64] = []
                                        for emoji in content.customEmoji {
                                            if !uniqueEmojiIds.contains(emoji.fileId) {
                                                uniqueEmojiIds.append(emoji.fileId)
                                                if uniqueEmojiIds.count >= maxEmojiCount {
                                                    break
                                                }
                                            }
                                        }
                                        
                                        var resolvedEmojiFiles: Signal<[Int64: String], NoError> = _internal_resolveInlineStickers(postbox: stateManager.postbox, network: stateManager.network, fileIds: uniqueEmojiIds)
                                        |> mapToSignal { files -> Signal<[Int64: String], NoError> in
                                            var fetchSignals: [Signal<(Int64, String?), NoError>] = []
                                            
                                            for (_, file) in files {
                                                if let resource = file.resource as? TelegramMultipartFetchableResource {
                                                    let fetchSignal: Signal<(Int64, String?), NoError>
                                                    if let path = stateManager.postbox.mediaBox.completedResourcePath(resource) {
                                                        fetchSignal = .single((file.fileId.id, path))
                                                    } else {
                                                        let intervals: Signal<[(Range<Int64>, MediaBoxFetchPriority)], NoError> = .single([(0 ..< Int64.max, MediaBoxFetchPriority.maximum)])
                                                        let fetchDataSignal: Signal<Data?, NoError> = Signal { subscriber in
                                                            final class DataValue {
                                                                var data = Data()
                                                                var missingRanges = RangeSet<Int64>(0 ..< Int64.max)
                                                            }
                                                            
                                                            let collectedData = Atomic<DataValue>(value: DataValue())
                                                            
                                                            return standaloneMultipartFetch(
                                                                accountPeerId: stateManager.accountPeerId,
                                                                postbox: stateManager.postbox,
                                                                network: stateManager.network,
                                                                resource: resource,
                                                                datacenterId: resource.datacenterId,
                                                                size: nil,
                                                                intervals: intervals,
                                                                parameters: MediaResourceFetchParameters(
                                                                    tag: nil,
                                                                    info: resourceFetchInfo(resource: resource),
                                                                    location: messageId.flatMap { messageId in
                                                                        return MediaResourceStorageLocation(
                                                                            peerId: peerId,
                                                                            messageId: messageId
                                                                        )
                                                                    },
                                                                    contentType: .sticker,
                                                                    isRandomAccessAllowed: true
                                                                ),
                                                                encryptionKey: nil,
                                                                decryptedSize: nil,
                                                                continueInBackground: false,
                                                                useMainConnection: true
                                                            ).start(request: requestWork, next: { result in
                                                                switch result {
                                                                case let .dataPart(offset, data, dataRange, _):
                                                                    var isCompleted = false
                                                                    let _ = collectedData.modify { current in
                                                                        let current = current
                                                                        
                                                                        let fillRange = Int(offset) ..< (Int(offset) + data.count)
                                                                        if current.data.count < fillRange.upperBound {
                                                                            current.data.count = fillRange.upperBound
                                                                        }
                                                                        current.data.withUnsafeMutableBytes { buffer -> Void in
                                                                            let bytes = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                                                                            data.copyBytes(to: bytes.advanced(by: Int(offset)), from: Int(dataRange.lowerBound) ..< Int(dataRange.upperBound))
                                                                        }
                                                                        current.missingRanges.remove(contentsOf: Int64(fillRange.lowerBound) ..< Int64(fillRange.upperBound))
                                                                        
                                                                        if current.missingRanges.isEmpty {
                                                                            isCompleted = true
                                                                        }
                                                                        return current
                                                                    }
                                                                    if isCompleted {
                                                                        let data = collectedData.with({ $0.data })
                                                                        subscriber.putNext( data)
                                                                        subscriber.putCompletion()
                                                                    }
                                                                case let .resourceSizeUpdated(size):
                                                                    var isCompleted = false
                                                                    let _ = collectedData.modify { current in
                                                                        let current = current
                                                                        current.missingRanges.remove(contentsOf: size ..< Int64.max)
                                                                        if current.missingRanges.isEmpty {
                                                                            isCompleted = true
                                                                        }
                                                                        return current
                                                                    }
                                                                    if isCompleted {
                                                                        let data = collectedData.with({ $0.data })
                                                                        subscriber.putNext(data)
                                                                        subscriber.putCompletion()
                                                                    }
                                                                default:
                                                                    break
                                                                }
                                                            }, error: { _ in
                                                                subscriber.putNext(nil)
                                                                subscriber.putCompletion()
                                                            }, completed: {
                                                                let data = collectedData.with({ $0.data })
                                                                subscriber.putNext(data)
                                                                subscriber.putCompletion()
                                                            })
                                                        }
                                                        fetchSignal = fetchDataSignal |> map { data -> (Int64, String?) in
                                                            guard let data else {
                                                                return (file.fileId.id, nil)
                                                            }
                                                            stateManager.postbox.mediaBox.storeResourceData(resource.id, data: data, synchronous: true)
                                                            if let path = stateManager.postbox.mediaBox.completedResourcePath(resource) {
                                                                return (file.fileId.id, path)
                                                            } else {
                                                                return (file.fileId.id, nil)
                                                            }
                                                        }
                                                    }
                                                    fetchSignals.append(fetchSignal)
                                                }
                                            }
                                            return combineLatest(fetchSignals)
                                            |> map { results -> [Int64: String] in
                                                var result: [Int64: String] = [:]
                                                for (id, path) in results {
                                                    if let path {
                                                        result[id] = path
                                                    }
                                                }
                                                return result
                                            }
                                        }

                                        if connectionGaveUp.with({ $0 }) {
                                            // The poll never got a connection. Each fetch below would only sit
                                            // out its own 10 s timeout on the same dead connection, past the
                                            // point where iOS expires the extension.
                                            Logger.shared.log("NotificationService \(episode)", "Skipping media fetches: no connection during the poll")
                                            fetchMediaSignal = .single(nil)
                                            fetchNotificationSoundSignal = .single(nil)
                                            resolvedEmojiFiles = .single([:])
                                        }

                                        // Each fetch gets at most 10 s, and never more than is left before
                                        // the deadline.
                                        let fetchBudget = min(10.0, remainingBudget())

                                        Logger.shared.log("NotificationService \(episode)", "Will fetch media")
                                        let _ = (combineLatest(queue: queue,
                                            fetchMediaSignal
                                            |> timeout(fetchBudget, queue: queue, alternate: .single(nil)),
                                            fetchNotificationSoundSignal
                                            |> timeout(fetchBudget, queue: queue, alternate: .single(nil)),
                                            wasDisplayed,
                                            resolvedEmojiFiles
                                            |> timeout(fetchBudget, queue: queue, alternate: .single([:])),
                                        )
                                        |> deliverOn(queue)).start(request: requestWork, next: { mediaData, notificationSoundData, wasDisplayed, resolvedEmojiFiles in
                                            guard let strongSelf = self, let stateManager = strongSelf.stateManager else {
                                                completed()
                                                return
                                            }
                                            
                                            shouldKeepConnection.set(.single(false))

                                            Logger.shared.log("NotificationService \(episode)", "Did fetch media \(mediaData == nil ? "Empty" : "Non-empty")")
                                            
                                            if let notificationSoundData = notificationSoundData {
                                                Logger.shared.log("NotificationService \(episode)", "Did fetch notificationSoundData")
                                                
                                                if let (_, filePath, _) = downloadNotificationSound {
                                                    let _ = try? notificationSoundData.write(to: URL(fileURLWithPath: filePath))
                                                }
                                            }

                                            Logger.shared.log("NotificationService \(episode)", "Will get unread count")
                                            let _ = (getCurrentRenderedTotalUnreadCount(
                                                accountManager: strongSelf.accountManager,
                                                postbox: stateManager.postbox
                                            )
                                            |> deliverOn(strongSelf.queue)).start(request: requestWork, next: { value in
                                                guard let strongSelf = self, let stateManager = strongSelf.stateManager else {
                                                    completed()
                                                    return
                                                }

                                                if isCurrentAccount {
                                                    content.badge = Int(value.0)
                                                }

                                                Logger.shared.log("NotificationService \(episode)", "Unread count: \(value.0), isCurrentAccount: \(isCurrentAccount)")
                                                
                                                Logger.shared.log("NotificationService \(episode)", "mediaAttachment: \(String(describing: mediaAttachment)), mediaData: \(String(describing: mediaData?.count))")

                                                var pendingAutosave: Signal<Never, NoError> = .complete()
                                                let finalizeContent: () -> Void = {
                                                    content.resolvedEmojiFiles = resolvedEmojiFiles
                                                    var persistDisplay: Signal<Never, NoError> = .complete()

                                                    Logger.shared.log("NotificationService \(episode)", "Updating content")

                                                    if wasDisplayed {
                                                        content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil, isEmpty: true, isMentionOrReply: isMentionOrReply, chatId: chatId)
                                                        Logger.shared.log("NotificationService \(episode)", "Was already displayed, skipping content")
                                                    } else if let messageId {
                                                        persistDisplay = stateManager.postbox.transaction { transaction -> Void in
                                                            _internal_setMessageNotificationWasDisplayed(transaction: transaction, id: messageId)
                                                        } |> ignoreValues
                                                    }

                                                    deliverCurrentContent(content)
                                                    let _ = (pendingAutosave |> then(persistDisplay) |> deliverOn(queue)).start(request: requestWork, completed: completed)
                                                }

                                                if let image = mediaAttachment as? TelegramMediaImage, let resource = largestImageRepresentation(image.representations)?.resource {
                                                    if let mediaData = mediaData {
                                                        stateManager.postbox.mediaBox.storeResourceData(resource.id, data: mediaData, synchronous: true)
                                                        if let messageId {
                                                            pendingAutosave = addSynchronizeAutosaveItemOperation(postbox: stateManager.postbox, messageId: messageId, mediaId: image.imageId)
                                                        }
                                                    }
                                                    if let storedPath = stateManager.postbox.mediaBox.completedResourcePath(resource, pathExtension: "jpg") {
                                                        if let attachment = try? UNNotificationAttachment(identifier: "image", url: URL(fileURLWithPath: storedPath), options: nil) {
                                                            content.attachments.append(attachment)
                                                        }
                                                    }
                                                } else if let file = mediaAttachment as? TelegramMediaFile {
                                                    if file.isStaticSticker {
                                                        let resource = file.resource

                                                        if let mediaData = mediaData {
                                                            stateManager.postbox.mediaBox.storeResourceData(resource.id, data: mediaData, synchronous: true)
                                                        }
                                                        if let storedPath = stateManager.postbox.mediaBox.completedResourcePath(resource) {
                                                            if let data = try? Data(contentsOf: URL(fileURLWithPath: storedPath)), let image = WebP.convert(fromWebP: data) {
                                                                let tempFile = TempBox.shared.tempFile(fileName: "image.png")
                                                                let _ = try? image.pngData()?.write(to: URL(fileURLWithPath: tempFile.path))
                                                                if let attachment = try? UNNotificationAttachment(identifier: "image", url: URL(fileURLWithPath: tempFile.path), options: nil) {
                                                                    content.attachments.append(attachment)
                                                                }
                                                            }
                                                        }
                                                    } else if file.isAnimatedSticker {
                                                        let resource = file.resource

                                                        if let mediaData = mediaData {
                                                            stateManager.postbox.mediaBox.storeResourceData(resource.id, data: mediaData, synchronous: true)
                                                        }
                                                        if let storedPath = stateManager.postbox.mediaBox.completedResourcePath(resource) {
                                                            if let data = try? Data(contentsOf: URL(fileURLWithPath: storedPath)), let image = convertLottieImage(data: data, size: CGSize(width: 200.0, height: 200.0), forceSquare: false) {
                                                                let tempFile = TempBox.shared.tempFile(fileName: "image.png")
                                                                let _ = try? image.pngData()?.write(to: URL(fileURLWithPath: tempFile.path))
                                                                if let attachment = try? UNNotificationAttachment(identifier: "image", url: URL(fileURLWithPath: tempFile.path), options: nil) {
                                                                    content.attachments.append(attachment)
                                                                }
                                                            }
                                                        }
                                                    } else if file.isVideo, let representation = file.previewRepresentations.first {
                                                        let resource = representation.resource

                                                        if let mediaData = mediaData {
                                                            stateManager.postbox.mediaBox.storeResourceData(resource.id, data: mediaData, synchronous: true)
                                                        }
                                                        if let storedPath = stateManager.postbox.mediaBox.completedResourcePath(resource, pathExtension: "jpg") {
                                                            if let attachment = try? UNNotificationAttachment(identifier: "image", url: URL(fileURLWithPath: storedPath), options: nil) {
                                                                content.attachments.append(attachment)
                                                            }
                                                        }
                                                    } else if file.isVoice {
                                                        if let mediaData = mediaData {
                                                            stateManager.postbox.mediaBox.storeResourceData(file.resource.id, data: mediaData, synchronous: true)
                                                        }
                                                        if let storedPath = stateManager.postbox.mediaBox.completedResourcePath(file.resource, pathExtension: nil) {
                                                            let tempFile = TempBox.shared.tempFile(fileName: "audio.m4a")
                                                            strongSelf.voiceConversionDisposable.set((convertOpusToAAC(sourcePath: storedPath, allocateTempFile: {
                                                                return tempFile.path
                                                            })
                                                            |> take(1)
                                                            |> timeout(min(5.0, remainingBudget()), queue: queue, alternate: .single(nil))
                                                            |> deliverOn(queue)).start(request: requestWork, next: { [weak self] convertedPath in
                                                                guard self != nil else { return }
                                                                // Keep the source until Notification Center has copied the attachment.
                                                                let _ = tempFile
                                                                if let convertedPath, let attachment = try? UNNotificationAttachment(identifier: "audio", url: URL(fileURLWithPath: convertedPath), options: nil) {
                                                                    content.attachments.append(attachment)
                                                                }
                                                                finalizeContent()
                                                            }))
                                                            return
                                                        }
                                                    }
                                                }
                                                
                                                finalizeContent()
                                            })
                                        })
                                    }
                                }

                                let pollSignal: Signal<Never, NoError>

                                if !shouldSynchronizeState {
                                    pollSignal = .complete()
                                } else {
                                    shouldKeepConnection.set(.single(true))
                                    let unboundedPollSignal: Signal<Never, NoError>
                                    if peerId.namespace == Namespaces.Peer.CloudChannel {
                                        Logger.shared.log("NotificationService \(episode)", "Will poll channel \(peerId)")

                                        unboundedPollSignal = standalonePollChannelOnce(
                                            accountPeerId: stateManager.accountPeerId,
                                            postbox: stateManager.postbox,
                                            network: stateManager.network,
                                            peerId: peerId,
                                            stateManager: stateManager
                                        )
                                    } else {
                                        Logger.shared.log("NotificationService \(episode)", "Will perform non-specific getDifference")
                                        enum ControlError {
                                            case restart
                                        }
                                        // Unbounded on its own: getDifference is paginated and restarted
                                        // until the state catches up, which never happens offline.
                                        unboundedPollSignal = stateManager.standalonePollDifference()
                                        |> castError(ControlError.self)
                                        |> mapToSignal { result -> Signal<Never, ControlError> in
                                            if result {
                                                return .complete()
                                            } else {
                                                return .fail(.restart)
                                            }
                                        }
                                        |> restartIfError
                                    }

                                    // `timeout` disposes the poll when it fires, which stops the
                                    // getDifference loop and its reconnects; the flag makes the fetch step
                                    // skip work that would only wait on the same dead connection. The
                                    // timer's handler can still run once after a completion it was too
                                    // late to cancel, hence the `pollCompleted` guard: a poll that just
                                    // made it keeps its fetches.
                                    let pollTimeout = min(pollBudget, remainingBudget())
                                    pollSignal = (unboundedPollSignal
                                    |> afterCompleted {
                                        let _ = pollCompleted.swap(true)
                                    })
                                    |> timeout(pollTimeout, queue: queue, alternate: Signal { subscriber in
                                        if !pollCompleted.with({ $0 }) {
                                            Logger.shared.log("NotificationService \(episode)", "Poll did not complete within \(pollTimeout) s, giving up on the connection")
                                            let _ = connectionGaveUp.swap(true)
                                        }
                                        subscriber.putCompletion()
                                        return EmptyDisposable
                                    })
                                }

                                let pollWithUpdatedContent: Signal<(NotificationContent, Media?), NoError>
                                if interactionAuthorId != nil || messageId != nil {
                                    pollWithUpdatedContent = stateManager.postbox.transaction { transaction -> (NotificationContent, Media?) in
                                        var content = initialContent
                                        
                                        if let interactionAuthorId = interactionAuthorId {
                                            if inAppNotificationSettings.displayNameOnLockscreen, var peer = transaction.getPeer(interactionAuthorId) {
                                                if let channel = peer as? TelegramChannel, channel.isMonoForum, let linkedMonoforumId = channel.linkedMonoforumId, let mainChannel = transaction.getPeer(linkedMonoforumId) {
                                                    peer = mainChannel
                                                }
                                                
                                                var foundLocalId: String?
                                                transaction.enumerateDeviceContactImportInfoItems({ _, value in
                                                    if let value = value as? TelegramDeviceContactImportedData {
                                                        switch value {
                                                        case let .imported(data, _, peerId):
                                                            if peerId == interactionAuthorId {
                                                                foundLocalId = data.localIdentifiers.first
                                                                return false
                                                            }
                                                        default:
                                                            break
                                                        }
                                                    }
                                                    return true
                                                })
                                                
                                                content.addSenderInfo(mediaBox: stateManager.postbox.mediaBox, accountPeerId: stateManager.accountPeerId, peer: peer, topicTitle: topicTitle, contactIdentifier: foundLocalId, isStory: false)
                                            }
                                        }
                                        
                                        if let messageId = messageId {
                                            if let readState = transaction.getCombinedPeerReadState(messageId.peerId) {
                                                for (namespace, state) in readState.states {
                                                    if namespace == messageId.namespace {
                                                        switch state {
                                                        case let .idBased(maxIncomingReadId, _, _, _, _):
                                                            if maxIncomingReadId >= messageId.id {
                                                                Logger.shared.log("NotificationService \(episode)", "maxIncomingReadId: \(maxIncomingReadId), messageId: \(messageId.id), skipping")
                                                                content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil, isEmpty: true, isMentionOrReply: isMentionOrReply, chatId: chatId)
                                                            } else {
                                                                Logger.shared.log("NotificationService \(episode)", "maxIncomingReadId: \(maxIncomingReadId), messageId: \(messageId.id), not skipping")
                                                            }
                                                        case .indexBased:
                                                            break
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        return (content, nil)
                                    }
                                    |> then(
                                        pollSignal
                                        |> map { _ -> (NotificationContent, Media?) in }
                                    )
                                    |> takeLast
                                    |> mapToSignal { content, _ -> Signal<(NotificationContent, Media?), NoError> in
                                        return stateManager.postbox.transaction { transaction -> (NotificationContent, Media?) in
                                            var content = content
                                            
                                            var parsedMedia: Media?
                                            if let messageId, let message = transaction.getMessage(messageId), !message.containsSecretMedia, !message.attributes.contains(where: { $0 is MediaSpoilerMessageAttribute }) {
                                                if let media = message.media.first {
                                                    parsedMedia = media
                                                }
                                                if enableInlineEmoji, let author = message.author {
                                                    let authorTitle = author.debugDisplayTitle
                                                    var needsPrefix = false
                                                    if message.id.peerId.namespace == Namespaces.Peer.CloudGroup {
                                                        needsPrefix = true
                                                    } else if let channel = message.peers[message.id.peerId] as? TelegramChannel {
                                                        if case .group = channel.info {
                                                            needsPrefix = true
                                                        }
                                                    }
                                                    let messagePrefix = needsPrefix ? "\(authorTitle): " : ""
                                                    let messagePrefixLength = (messagePrefix as NSString).length
                                                    if let textEntitiesAttribute = message.textEntitiesAttribute {
                                                        for entity in textEntitiesAttribute.entities {
                                                            if case let .CustomEmoji(_, fileId) = entity.type {
                                                                content.customEmoji.append(NotificationContent.CustomEmoji(range: (entity.range.lowerBound + messagePrefixLength) ..< (entity.range.upperBound + messagePrefixLength), fileId: fileId))
                                                            }
                                                        }
                                                        if !content.customEmoji.isEmpty {
                                                            content.body = messagePrefix + message.text
                                                        }
                                                    }
                                                    // A rich message's emoji are in its page, and its text is empty: the server's
                                                    // body is kept, with each emoji found in it by its alt text.
                                                    if content.customEmoji.isEmpty, let richText = message.richText, let body = content.body {
                                                        let page = richText.fullInstantPage ?? richText.instantPage
                                                        let start = body.hasPrefix(messagePrefix) ? messagePrefixLength : 0
                                                        for emoji in notificationRichTextCustomEmoji(body: body, from: start, runs: page.customEmojiTextRuns) {
                                                            content.customEmoji.append(NotificationContent.CustomEmoji(range: emoji.range, fileId: emoji.fileId))
                                                        }
                                                    }
                                                }
                                            }
                                            
                                            return (content, parsedMedia)
                                        }
                                    }
                                } else {
                                    pollWithUpdatedContent = pollSignal
                                    |> map { _ -> (NotificationContent, Media?) in }
                                }
                                
                                let reportDeliverySignal: Signal<Bool, NoError>
                                if reportDelivery, let messageId {
                                    // Combined with the poll below, so it needs the same deadline: a
                                    // request that never gets a connection would otherwise hold the
                                    // completion back even after the poll has given up. Delivery reports
                                    // are best-effort, so dropping the in-flight request is fine.
                                    reportDeliverySignal = _internal_reportMessageDelivery(postbox: stateManager.postbox, network: stateManager.network, messageIds: [messageId], fromPushNotification: true)
                                    |> timeout(remainingBudget(), queue: queue, alternate: .single(true))
                                } else {
                                    reportDeliverySignal = .single(true)
                                }

                                var updatedContent = initialContent
                                var updatedMedia: Media?
                                // The link is stored before any network work so the deadline and
                                // payload-only fallbacks, which still deliver this notification, find
                                // it committed; `then` keeps the fetch behind it.
                                let linkedPollWithUpdatedContent = (recordNotificationLink
                                |> map { _ -> (NotificationContent, Media?) in })
                                |> then(pollWithUpdatedContent)

                                strongSelf.pollDisposable.set(combineLatest(linkedPollWithUpdatedContent, reportDeliverySignal).start(request: requestWork, next: { contentAndMedia, _ in
                                    updatedContent = contentAndMedia.0
                                    updatedMedia = contentAndMedia.1
                                }, completed: {
                                    pollCompletion(updatedContent, updatedMedia)
                                }))
                            } else {
                                completed()
                            }
                        case let .pollStories(peerId, initialContent, storyId, isReaction):
                            Logger.shared.log("NotificationService \(episode)", "Will poll stories for \(peerId) isReaction: \(isReaction)")
                            if let stateManager = strongSelf.stateManager {
                                let pollCompletion: (NotificationContent) -> Void = { content in
                                    let content = content

                                    queue.async {
                                        guard let strongSelf = self, let stateManager = strongSelf.stateManager else {
                                            let content = NotificationContent(sgStatus: sgStatus, isLockedMessage: isReaction ? isLockedMessage : isLockedStoryMessage, isEmpty: true) // MARK: Swiftgram
                                            deliverCurrentContent(content)
                                            completed()
                                            return
                                        }
                                        
                                        let shouldKeepConnection = stateManager.network.shouldKeepConnection
                                        shouldKeepConnection.set(.single(true))
                                        
                                        var fetchStoriesSignal: Signal<Void, NoError> = .single(Void())
                                        fetchStoriesSignal = _internal_pollPeerStories(postbox: stateManager.postbox, network: stateManager.network, accountPeerId: stateManager.accountPeerId, peerId: peerId)
                                        |> map { _ -> Void in
                                        }
                                        |> then(
                                            stateManager.postbox.transaction { transaction -> (MediaResourceReference, Int64?)? in
                                                guard let state = transaction.getPeerStoryState(peerId: peerId)?.entry.get(Stories.PeerState.self) else {
                                                    return nil
                                                }
                                                let firstUnseenItem = transaction.getStoryItems(peerId: peerId).first(where: { entry in
                                                    return entry.id > state.maxReadId
                                                })
                                                if isReaction {
                                                    return nil
                                                } else {
                                                    guard let firstUnseenItem, firstUnseenItem.id == storyId else {
                                                        return nil
                                                    }
                                                }
                                                guard let peer = transaction.getPeer(peerId).flatMap(PeerReference.init) else {
                                                    return nil
                                                }
                                                
                                                if let storyItem = transaction.getStory(id: StoryId(peerId: peerId, id: storyId))?.get(Stories.StoredItem.self), case let .item(item) = storyItem, let media = item.media {
                                                    var resource: MediaResource?
                                                    var fetchSize: Int64?
                                                    if let image = media as? TelegramMediaImage {
                                                        resource = largestImageRepresentation(image.representations)?.resource
                                                    } else if let file = media as? TelegramMediaFile {
                                                        resource = file.resource
                                                        for attribute in file.attributes {
                                                            if case let .Video(_, _, _, preloadSize, _, _) = attribute {
                                                                fetchSize = preloadSize.flatMap(Int64.init)
                                                            }
                                                        }
                                                    }
                                                    
                                                    guard let resource else {
                                                        return nil
                                                    }
                                                    return (MediaResourceReference.media(media: .story(peer: peer, id: storyId, media: media), resource: resource), fetchSize)
                                                }
                                                
                                                return nil
                                            }
                                            |> mapToSignal { resourceData -> Signal<Void, NoError> in
                                                guard let (resource, _) = resourceData, let resourceValue = resource.resource as? TelegramMultipartFetchableResource else {
                                                    return .single(Void())
                                                }
                                                
                                                let intervals: Signal<[(Range<Int64>, MediaBoxFetchPriority)], NoError> = .single([(0 ..< Int64.max, MediaBoxFetchPriority.maximum)])
                                                return Signal<Void, NoError> { subscriber in
                                                    let collectedData = Atomic<Data>(value: Data())
                                                    return standaloneMultipartFetch(
                                                        accountPeerId: stateManager.accountPeerId,
                                                        postbox: stateManager.postbox,
                                                        network: stateManager.network,
                                                        resource: resourceValue,
                                                        datacenterId: resourceValue.datacenterId,
                                                        size: nil,
                                                        intervals: intervals,
                                                        parameters: MediaResourceFetchParameters(
                                                            tag: nil,
                                                            info: resourceFetchInfo(reference: resource),
                                                            location: .init(peerId: peerId, messageId: nil),
                                                            contentType: .other,
                                                            isRandomAccessAllowed: true
                                                        ),
                                                        encryptionKey: nil,
                                                        decryptedSize: nil,
                                                        continueInBackground: false,
                                                        useMainConnection: true
                                                    ).start(request: requestWork, next: { result in
                                                        switch result {
                                                        case let .dataPart(_, data, _, _):
                                                            let _ = collectedData.modify { current in
                                                                var current = current
                                                                current.append(data)
                                                                return current
                                                            }
                                                        default:
                                                            break
                                                        }
                                                    }, error: { _ in
                                                        subscriber.putNext(Void())
                                                        subscriber.putCompletion()
                                                    }, completed: {
                                                        stateManager.postbox.mediaBox.storeResourceData(resource.resource.id, data: collectedData.with({ $0 }))
                                                        subscriber.putNext(Void())
                                                        subscriber.putCompletion()
                                                    })
                                                }
                                            }
                                        )
                                        |> afterDisposed { [weak shouldKeepConnection] in
                                            shouldKeepConnection?.set(.single(false))
                                        }

                                        let fetchMediaSignal: Signal<Data?, NoError> = .single(nil)
                                        
                                        var fetchNotificationSoundSignal: Signal<Data?, NoError> = .single(nil)
                                        if let (downloadNotificationSound, _, _) = downloadNotificationSound {
                                            var fetchResource: TelegramMultipartFetchableResource?
                                            fetchResource = downloadNotificationSound.resource as? TelegramMultipartFetchableResource

                                            if let resource = fetchResource {
                                                if let path = strongSelf.stateManager?.postbox.mediaBox.completedResourcePath(resource), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                                                    fetchNotificationSoundSignal = .single(data)
                                                } else {
                                                    let intervals: Signal<[(Range<Int64>, MediaBoxFetchPriority)], NoError> = .single([(0 ..< Int64.max, MediaBoxFetchPriority.maximum)])
                                                    fetchNotificationSoundSignal = Signal { subscriber in
                                                        let collectedData = Atomic<Data>(value: Data())
                                                        return standaloneMultipartFetch(
                                                            accountPeerId: stateManager.accountPeerId,
                                                            postbox: stateManager.postbox,
                                                            network: stateManager.network,
                                                            resource: resource,
                                                            datacenterId: resource.datacenterId,
                                                            size: nil,
                                                            intervals: intervals,
                                                            parameters: MediaResourceFetchParameters(
                                                                tag: nil,
                                                                info: resourceFetchInfo(resource: resource),
                                                                location: nil,
                                                                contentType: .other,
                                                                isRandomAccessAllowed: true
                                                            ),
                                                            encryptionKey: nil,
                                                            decryptedSize: nil,
                                                            continueInBackground: false,
                                                            useMainConnection: true
                                                        ).start(request: requestWork, next: { result in
                                                            switch result {
                                                            case let .dataPart(_, data, _, _):
                                                                let _ = collectedData.modify { current in
                                                                    var current = current
                                                                    current.append(data)
                                                                    return current
                                                                }
                                                            default:
                                                                break
                                                            }
                                                        }, error: { _ in
                                                            subscriber.putNext(nil)
                                                            subscriber.putCompletion()
                                                        }, completed: {
                                                            subscriber.putNext(collectedData.with({ $0 }))
                                                            subscriber.putCompletion()
                                                        })
                                                    }
                                                }
                                            }
                                        }
                                        
                                        let wasDisplayed: Signal<Bool, NoError>
                                        if isReaction {
                                            wasDisplayed = .single(false)
                                        } else {
                                            wasDisplayed = stateManager.postbox.transaction { transaction -> Bool in
                                                return _internal_getStoryNotificationWasDisplayed(transaction: transaction, id: StoryId(peerId: peerId, id: storyId))
                                            }
                                        }

                                        Logger.shared.log("NotificationService \(episode)", "Will fetch media")
                                        let _ = (combineLatest(queue: queue,
                                            fetchMediaSignal
                                            |> timeout(budget.remaining(maximum: 10.0), queue: queue, alternate: .single(nil)),
                                            fetchNotificationSoundSignal
                                            |> timeout(budget.remaining(maximum: 10.0), queue: queue, alternate: .single(nil)),
                                            fetchStoriesSignal
                                            |> timeout(budget.remaining(maximum: 10.0), queue: queue, alternate: .single(Void())),
                                            wasDisplayed
                                        )
                                        |> deliverOn(queue)).start(request: requestWork, next: { mediaData, notificationSoundData, _, wasDisplayed in
                                            guard let strongSelf = self, let stateManager = strongSelf.stateManager else {
                                                completed()
                                                return
                                            }

                                            Logger.shared.log("NotificationService \(episode)", "Did fetch media \(mediaData == nil ? "Non-empty" : "Empty")")
                                            
                                            if let notificationSoundData = notificationSoundData {
                                                Logger.shared.log("NotificationService \(episode)", "Did fetch notificationSoundData")
                                                
                                                if let (_, filePath, _) = downloadNotificationSound {
                                                    let _ = try? notificationSoundData.write(to: URL(fileURLWithPath: filePath))
                                                }
                                            }
                                            
                                            var content = content
                                            var persistDisplay: Signal<Never, NoError> = .complete()
                                            if wasDisplayed {
                                                content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil, isEmpty: true)
                                            } else {
                                                persistDisplay = stateManager.postbox.transaction { transaction -> Void in
                                                    _internal_setStoryNotificationWasDisplayed(transaction: transaction, id: StoryId(peerId: peerId, id: storyId))
                                                } |> ignoreValues
                                            }

                                            Logger.shared.log("NotificationService \(episode)", "Updating content")

                                            deliverCurrentContent(content)

                                            let _ = (persistDisplay |> deliverOn(queue)).start(request: requestWork, completed: completed)
                                        })
                                    }
                                }

                                let pollWithUpdatedContent: Signal<NotificationContent, NoError>
                                if interactionAuthorId != nil || messageId != nil {
                                    pollWithUpdatedContent = stateManager.postbox.transaction { transaction -> NotificationContent in
                                        var content = initialContent
                                        
                                        if let interactionAuthorId = interactionAuthorId {
                                            if inAppNotificationSettings.displayNameOnLockscreen, var peer = transaction.getPeer(interactionAuthorId) {
                                                if let channel = peer as? TelegramChannel, channel.isMonoForum, let linkedMonoforumId = channel.linkedMonoforumId, let mainChannel = transaction.getPeer(linkedMonoforumId) {
                                                    peer = mainChannel
                                                }
                                                
                                                var foundLocalId: String?
                                                transaction.enumerateDeviceContactImportInfoItems({ _, value in
                                                    if let value = value as? TelegramDeviceContactImportedData {
                                                        switch value {
                                                        case let .imported(data, _, peerId):
                                                            if peerId == interactionAuthorId {
                                                                foundLocalId = data.localIdentifiers.first
                                                                return false
                                                            }
                                                        default:
                                                            break
                                                        }
                                                    }
                                                    return true
                                                })
                                                
                                                content.addSenderInfo(mediaBox: stateManager.postbox.mediaBox, accountPeerId: stateManager.accountPeerId, peer: peer, topicTitle: topicTitle, contactIdentifier: foundLocalId, isStory: false)
                                            }
                                        }

                                        return content
                                    }
                                } else {
                                    pollWithUpdatedContent = .complete()
                                }
                                
                                

                                var updatedContent = initialContent
                                strongSelf.pollDisposable.set(pollWithUpdatedContent.start(request: requestWork, next: { content in
                                    updatedContent = content
                                }, completed: {
                                    pollCompletion(updatedContent)
                                }))
                            } else {
                                completed()
                            }
                        case let .deleteMessage(ids):
                            Logger.shared.log("NotificationService \(episode)", "Will delete messages \(ids)")
                            let mediaBox = stateManager.postbox.mediaBox
                            let _ = (stateManager.postbox.transaction { transaction -> Void in
                                transaction.recordMessageDeletions(ids)
                                let remaining = _internal_conceptRetainDeletedMessages(transaction: transaction, ids: ids)
                                _internal_deleteMessages(transaction: transaction, mediaBox: mediaBox, ids: remaining, deleteMedia: true)
                            }
                            |> deliverOn(strongSelf.queue)).start(request: requestWork, completed: {
                                notificationDeliveredNotifications(request: requestWork, queue: queue, completionHandler: { notifications in
                                    var removeIdentifiers: [String] = []
                                    for notification in notifications {
                                        guard notificationBelongsToAccount(notification.request.content.userInfo, accountId: recordId.int64) else { continue }
                                        if let peerIdString = notification.request.content.userInfo["peerId"] as? String, let peerIdValue = Int64(peerIdString), let messageIdString = notification.request.content.userInfo["msg_id"] as? String, let messageIdValue = Int32(messageIdString) {
                                            for id in ids {
                                                if PeerId(peerIdValue) == id.peerId && messageIdValue == id.id {
                                                    removeIdentifiers.append(notification.request.identifier)
                                                }
                                            }
                                        }
                                    }

                                    let completeRemoval: () -> Void = {
                                        guard let strongSelf = self else {
                                            return
                                        }
                                        let _ = (getCurrentRenderedTotalUnreadCount(
                                            accountManager: strongSelf.accountManager,
                                            postbox: stateManager.postbox
                                        )
                                        |> deliverOn(strongSelf.queue)).start(request: requestWork, next: { value in
                                            var content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil, isEmpty: true) // MARK: Swiftgram
                                            if isCurrentAccount {
                                                content.badge = Int(value.0)
                                            }
                                            Logger.shared.log("NotificationService \(episode)", "Unread count: \(value.0), isCurrentAccount: \(isCurrentAccount)")
                                            Logger.shared.log("NotificationService \(episode)", "Updating content")

                                            deliverCurrentContent(content)

                                            completed()
                                        })
                                    }

                                    if !removeIdentifiers.isEmpty {
                                        Logger.shared.log("NotificationService \(episode)", "Will try to remove \(removeIdentifiers.count) notifications")
                                        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: removeIdentifiers)
                                        completeRemoval()
                                    } else {
                                        completeRemoval()
                                    }
                                })
                            })
                        case let .readReactions(ids):
                            Logger.shared.log("NotificationService \(episode)", "Will read reactions \(ids)")
                            notificationDeliveredNotifications(request: requestWork, queue: queue, completionHandler: { notifications in
                                var removeIdentifiers: [String] = []
                                for notification in notifications {
                                        guard notificationBelongsToAccount(notification.request.content.userInfo, accountId: recordId.int64) else { continue }
                                    if notification.request.content.categoryIdentifier != "t" {
                                        continue
                                    }
                                    if let peerIdString = notification.request.content.userInfo["peerId"] as? String, let peerIdValue = Int64(peerIdString), let messageIdString = notification.request.content.userInfo["msg_id"] as? String, let messageIdValue = Int32(messageIdString) {
                                        for id in ids {
                                            if PeerId(peerIdValue) == id.peerId && messageIdValue == id.id {
                                                removeIdentifiers.append(notification.request.identifier)
                                            }
                                        }
                                    }
                                }
                                
                                let completeRemoval: () -> Void = {
                                    let content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil, isEmpty: true) // MARK: Swiftgram
                                    Logger.shared.log("NotificationService \(episode)", "Updating content")
                                    
                                    deliverCurrentContent(content)
                                    
                                    completed()
                                }
                                
                                if !removeIdentifiers.isEmpty {
                                    Logger.shared.log("NotificationService \(episode)", "Will try to remove \(removeIdentifiers.count) notifications")
                                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: removeIdentifiers)
                                    completeRemoval()
                                } else {
                                    completeRemoval()
                                }
                            })
                        case let .readMessage(id):
                            Logger.shared.log("NotificationService \(episode)", "Will read message \(id)")
                            let _ = (stateManager.postbox.transaction { transaction -> Void in
                                transaction.applyIncomingReadMaxId(id)
                            }
                            |> deliverOn(strongSelf.queue)).start(request: requestWork, completed: {
                                notificationDeliveredNotifications(request: requestWork, queue: queue, completionHandler: { notifications in
                                    let notificationDebugList = notifications.map { notification -> String in
                                        if let peerIdString = notification.request.content.userInfo["peerId"] as? String, let peerIdValue = Int64(peerIdString), let messageIdString = notification.request.content.userInfo["msg_id"] as? String, let messageIdValue = Int32(messageIdString) {
                                            return "peerId: \(peerIdValue), messageId: \(messageIdValue)"
                                        } else {
                                            return "unknown: \(String(describing: notification.request.content.userInfo))"
                                        }
                                    }.joined(separator: "\n")
                                    Logger.shared.log("NotificationService \(episode)", "Filtering delivered notifications: \(notificationDebugList)")
                                    
                                    var removeIdentifiers: [String] = []
                                    for notification in notifications {
                                        guard notificationBelongsToAccount(notification.request.content.userInfo, accountId: recordId.int64) else { continue }
                                        if let peerIdString = notification.request.content.userInfo["peerId"] as? String, let peerIdValue = Int64(peerIdString), let messageIdString = notification.request.content.userInfo["msg_id"] as? String, let messageIdValue = Int32(messageIdString) {
                                            if PeerId(peerIdValue) == id.peerId && messageIdValue <= id.id {
                                                removeIdentifiers.append(notification.request.identifier)
                                            }
                                        }
                                    }

                                    let completeRemoval: () -> Void = {
                                        guard let strongSelf = self else {
                                            return
                                        }
                                        let _ = (getCurrentRenderedTotalUnreadCount(
                                            accountManager: strongSelf.accountManager,
                                            postbox: stateManager.postbox
                                        )
                                        |> deliverOn(strongSelf.queue)).start(request: requestWork, next: { value in
                                            var content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil, isEmpty: true) // MARK: Swiftgram
                                            if isCurrentAccount {
                                                content.badge = Int(value.0)
                                            }

                                            Logger.shared.log("NotificationService \(episode)", "Unread count: \(value.0), isCurrentAccount: \(isCurrentAccount)")
                                            Logger.shared.log("NotificationService \(episode)", "Updating content")

                                            deliverCurrentContent(content)

                                            completed()
                                        })
                                    }

                                    if !removeIdentifiers.isEmpty {
                                        Logger.shared.log("NotificationService \(episode)", "Will try to remove \(removeIdentifiers.count) notifications")
                                        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: removeIdentifiers)
                                        completeRemoval()
                                    } else {
                                        completeRemoval()
                                    }
                                })
                            })
                        case let .readStories(peerId, maxId):
                            Logger.shared.log("NotificationService \(episode)", "Will read stories peerId: \(peerId) maxId: \(maxId)")
                            let _ = (stateManager.postbox.transaction { transaction -> Void in
                            }
                            |> deliverOn(strongSelf.queue)).start(request: requestWork, completed: {
                                notificationDeliveredNotifications(request: requestWork, queue: queue, completionHandler: { notifications in
                                    var removeIdentifiers: [String] = []
                                    for notification in notifications {
                                        guard notificationBelongsToAccount(notification.request.content.userInfo, accountId: recordId.int64) else { continue }
                                        if let peerIdString = notification.request.content.userInfo["peerId"] as? String, let peerIdValue = Int64(peerIdString), let messageIdString = notification.request.content.userInfo["story_id"] as? String, let messageIdValue = Int32(messageIdString) {
                                            if PeerId(peerIdValue) == peerId && messageIdValue <= maxId {
                                                removeIdentifiers.append(notification.request.identifier)
                                            }
                                        }
                                    }

                                    let completeRemoval: () -> Void = {
                                        let content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil, isEmpty: true) // MARK: Swiftgram
                                        deliverCurrentContent(content)
                                        
                                        completed()
                                    }

                                    if !removeIdentifiers.isEmpty {
                                        Logger.shared.log("NotificationService \(episode)", "Will try to remove \(removeIdentifiers.count) notifications")
                                        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: removeIdentifiers)
                                        completeRemoval()
                                    } else {
                                        completeRemoval()
                                    }
                                })
                            })
                        }
                    } else {
                        let content = NotificationContent(sgStatus: sgStatus, isLockedMessage: nil) // MARK: Swiftgram
                        deliverCurrentContent(content)

                        completed()
                    }
                }))
            }))
        }))
    }

    deinit {
        self.preparationDisposable.dispose()
        self.stateManagerDisposable.dispose()
        self.notificationKeyDisposable.dispose()
        self.pollDisposable.dispose()
        self.voiceConversionDisposable.dispose()
        self.stateManager?.network.shouldKeepConnection.set(.single(false))
    }
}

