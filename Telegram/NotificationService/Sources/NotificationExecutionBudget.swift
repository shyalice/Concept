import Foundation

/// A monotonic deadline from didReceive, including time spent waiting for the
/// processing queue and opening the database. Wall-clock adjustments cannot add
/// another network/fetch window. Five seconds remain for the system handoff.
struct NotificationExecutionBudget {
    private let deadline: TimeInterval
    private let now: () -> TimeInterval

    init(duration: TimeInterval = 25.0, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        self.deadline = now() + max(0, duration)
    }

    func remaining(maximum: TimeInterval = .greatestFiniteMagnitude) -> TimeInterval {
        return max(0, min(maximum, self.deadline - self.now()))
    }
}

/// Notification Center contains notifications for every signed-in account.
/// Missing/foreign account identities must never remove another account's item.
func notificationBelongsToAccount(_ userInfo: [AnyHashable: Any], accountId: Int64) -> Bool {
    if let value = userInfo["accountId"] as? String { return Int64(value) == accountId }
    if let value = userInfo["accountId"] as? NSNumber { return value.int64Value == accountId }
    return false
}
