import Foundation

/// Separates successful system handoff from cancellation. Normal Signal disposal
/// after completion must not remove a notification that was successfully added.
public final class NotificationDeliveryCommit {
    private enum Phase { case pending, committed, cancelled }
    private let lock = NSLock()
    private var phase = Phase.pending
    public init() {}
    @discardableResult public func commit() -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        guard case .pending = self.phase else { return false }
        self.phase = .committed; return true
    }
    @discardableResult public func cancel() -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        guard case .pending = self.phase else { return false }
        self.phase = .cancelled; return true
    }
}
