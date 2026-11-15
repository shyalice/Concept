import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import AccountContext
import ConceptNotifications

final class ConceptLocalNotificationService {
    private weak var context: SharedApplicationContext?
    private let accounts = NotificationAccountSubscriptions<AccountRecordId>()
    private let observation = MetaDisposable()
    private var readTrackers: [AccountRecordId: ConceptNotificationReadTracker] = [:]
    private var settings = InAppNotificationSettings.defaultSettings
    private var eligibleAccounts = Set<AccountRecordId>()
    private var leasedAccounts = Set<AccountRecordId>()
    private var networkLease: Disposable?
    private var observers: [NSObjectProtocol] = []
    private var isInBackground = UIApplication.shared.applicationState == .background

    init(context: SharedApplicationContext) {
        self.context = context
        let shared = context.sharedContext
        conceptRemoveHiddenNotifications(sharedContext: shared)
        self.observation.set((combineLatest(queue: .mainQueue(),
            shared.activeAccountContexts,
            shared.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.inAppNotificationSettings]),
            shared.conceptSecretPasscodes)
        |> deliverOnMainQueue).start(next: { [weak self, weak context] active, preferences, rawSecrets in
            guard let self, let context else { return }
            self.settings = preferences.entries[ApplicationSpecificSharedDataKeys.inAppNotificationSettings]?.get(InAppNotificationSettings.self) ?? .defaultSettings
            let secrets = rawSecrets.withCheckedTimeoutUsingLockStateFile(rootPath: shared.basePath)
            let hidden = secrets.inactiveAccountIds()
            let contexts = Dictionary(uniqueKeysWithValues: active.accounts.filter { !hidden.contains($0.0) }.map { ($0.0, $0.1) })
            self.eligibleAccounts = Set(contexts.keys)
            for id in Array(self.readTrackers.keys) where contexts[id] == nil { self.readTrackers.removeValue(forKey: id) }
            for (id, account) in contexts where self.readTrackers[id] == nil {
                self.readTrackers[id] = ConceptNotificationReadTracker(account: account)
            }
            self.accounts.update(contexts.mapValues { ObjectIdentifier($0.account) }, subscribe: { id in
                guard let account = contexts[id] else { return EmptyDisposable }
                return (account.account.stateManager.notificationMessages
                |> deliverOnMainQueue
                |> beforeNext { [weak self] _ in
                    self?.readTrackers[id]?.refresh()
                    Queue.mainQueue().after(1.0) { [weak self] in self?.readTrackers[id]?.refresh() }
                }
                |> mapToQueue { [weak self, weak context] messageList -> Signal<Void, NoError> in
                    guard let self, let context, BackgroundNotificationSettings.isEnabled,
                          UIApplication.shared.applicationState != .active else { return .complete() }
                    let messages = messageList.compactMap { item -> EngineMessage? in
                        let (messages, _, notify, _) = item
                        return notify ? messages.first.map { EngineMessage($0) } : nil
                    }
                    return deliverConceptLocalNotifications(messages: messages, account: account, sharedContext: context, settings: self.settings)
                }).start()
            })
            self.updateNetworkLease()
        }))
        let center = NotificationCenter.default
        self.observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isInBackground = true
            self?.updateNetworkLease()
        })
        self.observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isInBackground = false
            self?.updateNetworkLease()
            if let shared = self?.context?.sharedContext { conceptRemoveHiddenNotifications(sharedContext: shared) }
            self?.refreshReadNotifications()
        })
        self.observers.append(center.addObserver(forName: LocalNotificationRoute.requestsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshReadNotifications()
        })
        self.observers.append(center.addObserver(forName: BackgroundNotificationSettings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.updateNetworkLease()
        })
    }

    private func refreshReadNotifications() {
        for tracker in self.readTrackers.values { tracker.refresh() }
    }

    private func updateNetworkLease() {
        let ids = self.isInBackground && BackgroundNotificationSettings.isEnabled ? self.eligibleAccounts : []
        guard ids != self.leasedAccounts else { return }
        let previous = self.networkLease
        self.networkLease = ids.isEmpty ? nil : self.context?.wakeupManager.acquireNotificationRefreshLease(accounts: ids)
        self.leasedAccounts = ids
        previous?.dispose()
    }

    deinit {
        self.observation.dispose()
        self.accounts.dispose()
        self.networkLease?.dispose()
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
    }
}
