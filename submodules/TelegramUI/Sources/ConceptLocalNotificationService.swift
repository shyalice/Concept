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
    private var readRefreshTimer: SwiftSignalKit.Timer?
    private var trailingReadRefreshTimer: SwiftSignalKit.Timer?
    private var readRefreshInFlight = false
    private var readRefreshPending = false
    private var isInBackground = UIApplication.shared.applicationState == .background

    init(context: SharedApplicationContext) {
        self.context = context
        let shared = context.sharedContext
        conceptRemoveHiddenNotifications(sharedContext: shared)
        self.observation.set((combineLatest(queue: .mainQueue(),
            shared.activeAccountContexts,
            shared.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.inAppNotificationSettings]),
            shared.conceptSecretPasscodes,
            BackgroundNotificationSettings.enabledSignal)
        |> deliverOnMainQueue).start(next: { [weak self, weak context] active, preferences, rawSecrets, enabled in
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
            self.refreshReadNotifications()
            self.accounts.update(enabled ? contexts.mapValues { ObjectIdentifier($0.account) } : [:], subscribe: { id in
                guard let account = contexts[id] else { return EmptyDisposable }
                return (account.account.stateManager.notificationMessages
                |> deliverOnMainQueue
                |> beforeNext { [weak self] _ in
                    self?.refreshReadNotifications()
                    self?.scheduleTrailingReadRefresh()
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

    private func scheduleTrailingReadRefresh() {
        guard self.trailingReadRefreshTimer == nil else { return }
        let timer = SwiftSignalKit.Timer(timeout: 1.0, repeat: false, completion: { [weak self] in
            self?.trailingReadRefreshTimer = nil
            self?.refreshReadNotifications()
        }, queue: .mainQueue())
        self.trailingReadRefreshTimer = timer
        timer.start()
    }

    private func refreshReadNotifications() {
        guard self.readRefreshTimer == nil else { return }
        let timer = SwiftSignalKit.Timer(timeout: 0.2, repeat: false, completion: { [weak self] in
            self?.readRefreshTimer = nil
            self?.fetchReadNotifications()
        }, queue: .mainQueue())
        self.readRefreshTimer = timer
        timer.start()
    }

    private func fetchReadNotifications() {
        guard !self.readRefreshInFlight else { self.readRefreshPending = true; return }
        guard !self.readTrackers.isEmpty else { return }
        self.readRefreshInFlight = true
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { [weak self] delivered in
            center.getPendingNotificationRequests { pending in
                Queue.mainQueue().async {
                    guard let self else { return }
                    self.readRefreshInFlight = false
                    let requests = delivered.map(\.request) + pending
                    for tracker in self.readTrackers.values { tracker.reconcile(requests) }
                    if self.readRefreshPending {
                        self.readRefreshPending = false
                        self.refreshReadNotifications()
                    }
                }
            }
        }
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
        self.readRefreshTimer?.invalidate()
        self.trailingReadRefreshTimer?.invalidate()
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
    }
}
