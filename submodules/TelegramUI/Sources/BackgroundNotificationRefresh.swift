import Foundation
import UIKit
import BackgroundTasks
import UserNotifications
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import AccountContext
import AppLockState
import ConceptNotifications

/// Periodic, best-effort synchronization. This never claims to replace APNs or
/// to choose its own wake-up interval. iOS owns scheduling and may not run it.
final class BackgroundNotificationRefresh {
    private let identifier: String
    private let perform: (@escaping (Bool) -> Void) -> Disposable
    private var observer: NSObjectProtocol?
    private var currentId: UUID?
    private var current: NotificationOnceCompletion<Bool>?
    private let work = MetaDisposable()

    init(identifier: String, perform: @escaping (@escaping (Bool) -> Void) -> Disposable) {
        self.identifier = identifier
        self.perform = perform
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let self, let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            self.begin(task)
        }
        self.observer = NotificationCenter.default.addObserver(forName: BackgroundNotificationSettings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.schedule()
        }
        self.schedule()
    }

    func schedule() {
        guard BackgroundNotificationSettings.isEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: self.identifier)
            self.current?.finish(false)
            return
        }
        guard UIApplication.shared.backgroundRefreshStatus == .available else { return }
        BGTaskScheduler.shared.getPendingTaskRequests { [weak self] tasks in
            Queue.mainQueue().async {
                guard let self, BackgroundNotificationSettings.isEnabled, !tasks.contains(where: { $0.identifier == self.identifier }) else { return }
                let request = BGAppRefreshTaskRequest(identifier: self.identifier)
                // A lower bound, not a 15-minute timer. iOS may delay or omit it.
                request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
                do { try BGTaskScheduler.shared.submit(request) }
                catch { UserDefaults.standard.set(String(describing: error), forKey: "Concept.BackgroundNotifications.SchedulingError") }
            }
        }
    }

    private func begin(_ task: BGAppRefreshTask) {
        guard BackgroundNotificationSettings.isEnabled else { task.setTaskCompleted(success: false); return }
        self.current?.finish(false)
        let work = MetaDisposable()
        let currentId = UUID()
        self.currentId = currentId
        self.work.set(work)
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let completion = NotificationOnceCompletion<Bool> { [weak self] success in
            watchdog.setEventHandler {}
            watchdog.cancel()
            work.dispose()
            BackgroundNotificationSettings.record(completed: success)
            task.setTaskCompleted(success: success)
            Queue.mainQueue().async {
                if self?.currentId == currentId { self?.current = nil; self?.currentId = nil }
            }
        }
        self.current = completion
        task.expirationHandler = { completion.finish(false) }
        watchdog.schedule(deadline: .now() + 25.0)
        watchdog.setEventHandler { completion.finish(false) }
        watchdog.resume()
        self.schedule()
        work.set(self.perform { completion.finish($0) })
    }

    deinit {
        if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
        self.current?.finish(false)
        self.work.dispose()
    }
}

func runBackgroundNotificationRefresh(context: SharedApplicationContext) -> Signal<Bool, NoError> {
    let shared = context.sharedContext
    let authorized = Signal<Bool, NoError> { subscriber in
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional || settings.authorizationStatus == .ephemeral
            subscriber.putNext(allowed); subscriber.putCompletion()
        }
        return EmptyDisposable
    }
    return authorized |> deliverOnMainQueue |> mapToSignal { authorized -> Signal<Bool, NoError> in
        guard authorized else { return .single(false) }
        return combineLatest(queue: .mainQueue(), shared.activeAccountContexts |> take(1), shared.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.inAppNotificationSettings, SharedDataKeys.conceptSecretPasscodes]) |> take(1))
        |> mapToSignal { accounts, data -> Signal<Bool, NoError> in
            guard BackgroundNotificationSettings.isEnabled else { return .single(false) }
            let secrets = (data.entries[SharedDataKeys.conceptSecretPasscodes]?.get(ConceptSecretPasscodes.self) ?? .defaultSettings).withCheckedTimeoutUsingLockStateFile(rootPath: shared.basePath)
            let hiddenAccounts = secrets.inactiveAccountIds()
            let selected = accounts.accounts.filter { !hiddenAccounts.contains($0.0) }
            guard !selected.isEmpty else { return .single(true) }
            return Signal { subscriber in
                let lease = context.wakeupManager.acquireNotificationRefreshLease(accounts: Set(selected.map { $0.0 }))
                let hiddenByAccount = Dictionary(uniqueKeysWithValues: selected.map { ($0.0, secrets.inactiveSecretChatPeerIds(accountId: $0.0)) })
                let signals = selected.map { id, account, _ -> Signal<Bool, NoError> in
                    return account.engine.messages.refreshBackgroundNotificationCandidates()
                    |> deliverOnMainQueue
                    |> mapToSignal { candidates -> Signal<Bool, NoError> in
                        var deliveries: Signal<Bool, NoError> = .single(true)
                        for candidate in candidates where hiddenByAccount[id]?.contains(candidate.message.id.peerId) != true {
                            deliveries = deliveries |> mapToSignal { success in
                                return deliverBackgroundCandidate(candidate, account: account, context: context)
                                |> map { success && $0 }
                            }
                        }
                        return deliveries
                    }
                }
                let work = (combineLatest(signals) |> map { !$0.contains(false) }).start(next: subscriber.putNext, completed: subscriber.putCompletion)
                return ActionDisposable { work.dispose(); lease.dispose() }
            }
        }
    }
}

private func deliverBackgroundCandidate(_ candidate: EngineBackgroundNotificationCandidate, account: AccountContext, context: SharedApplicationContext) -> Signal<Bool, NoError> {
    guard BackgroundNotificationSettings.isEnabled, UIApplication.shared.applicationState != .active else { return .single(true) }
    let id = candidate.message.id
    let claim = UUID().uuidString
    return account.engine.messages.claimBackgroundNotification(id: id, token: claim)
    |> deliverOnMainQueue
    |> mapToSignal { candidate -> Signal<Bool, NoError> in
        guard let candidate else { return .single(true) }
        let shared = context.sharedContext
        return combineLatest(queue: .mainQueue(),
            shared.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.inAppNotificationSettings, SharedDataKeys.conceptSecretPasscodes]) |> take(1),
            shared.activeAccountContexts |> take(1))
        |> mapToSignal { latest, _ -> Signal<Bool, NoError> in
            let settings = latest.entries[ApplicationSpecificSharedDataKeys.inAppNotificationSettings]?.get(InAppNotificationSettings.self) ?? .defaultSettings
            let secrets = (latest.entries[SharedDataKeys.conceptSecretPasscodes]?.get(ConceptSecretPasscodes.self) ?? .defaultSettings).withCheckedTimeoutUsingLockStateFile(rootPath: shared.basePath)
            guard BackgroundNotificationSettings.isEnabled, UIApplication.shared.applicationState != .active,
                  !secrets.inactiveAccountIds().contains(account.account.id),
                  !secrets.inactiveSecretChatPeerIds(accountId: account.account.id).contains(id.peerId) else {
                return Signal { subscriber in
                    return account.engine.messages.releaseBackgroundNotificationClaim(id: id, token: claim).start(completed: { subscriber.putNext(true); subscriber.putCompletion() })
                }
            }
            let locked: Bool
            if let raw = try? Data(contentsOf: URL(fileURLWithPath: appLockStatePath(rootPath: shared.basePath))), let state = try? JSONDecoder().decode(LockState.self, from: raw) { locked = isAppLocked(state: state) } else { locked = false }
            return Signal { subscriber in
                guard let notification = conceptLocalNotificationContent(candidate: candidate, account: account, settings: settings, locked: locked) else {
                    return account.engine.messages.releaseBackgroundNotificationClaim(id: id, token: claim).start(completed: {
                        subscriber.putNext(true)
                        subscriber.putCompletion()
                    })
                }
                let identifier = notification.identifier
                let request = UNNotificationRequest(identifier: identifier, content: notification.content, trigger: nil)
                let center = UNUserNotificationCenter.current()
                let gate = NotificationDeliveryCommit()
                let work = MetaDisposable()
                let remove = {
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                    center.removeDeliveredNotifications(withIdentifiers: [identifier])
                }
                let release = {
                    _ = account.engine.messages.releaseBackgroundNotificationClaim(id: id, token: claim).startStandalone()
                }
                center.add(request) { error in
                    guard gate.commit() else { remove(); release(); return }
                    if error == nil && BackgroundNotificationSettings.isEnabled {
                        work.set(account.engine.messages.commitBackgroundNotificationClaim(id: id, token: claim).start(completed: { subscriber.putNext(true); subscriber.putCompletion() }))
                    } else {
                        remove()
                        work.set(account.engine.messages.releaseBackgroundNotificationClaim(id: id, token: claim).start(completed: { subscriber.putNext(false); subscriber.putCompletion() }))
                    }
                }
                return ActionDisposable {
                    if gate.cancel() { remove(); release() }
                    work.dispose()
                }
            }
        }
    }
}
