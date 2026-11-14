import Foundation

/// Owns every operation started for one push, including subscriptions created by
/// a late callback. Registering after cancellation disposes immediately.
final class NotificationRequestWork: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellations: [() -> Void] = []

    var isCancelled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cancelled
    }

    func addCancellation(_ action: @escaping () -> Void) {
        self.lock.lock()
        if self.cancelled {
            self.lock.unlock()
            action()
        } else {
            self.cancellations.append(action)
            self.lock.unlock()
        }
    }

    func cancel() {
        self.lock.lock()
        guard !self.cancelled else { self.lock.unlock(); return }
        self.cancelled = true
        let actions = self.cancellations
        self.cancellations.removeAll()
        self.lock.unlock()
        for action in actions { action() }
    }

    deinit { self.cancel() }
}

/// Fetch completion, a watchdog and Apple's expiry callback may race. Only one
/// can deliver the latest immutable snapshot. Work is stopped outside the lock.
final class NotificationRequestCompletion<Content>: @unchecked Sendable {
    enum FinishReason: Equatable { case completed, deadline, systemExpiry }
    private let lock = NSLock()
    private var content: Content?
    private var handler: ((Content) -> Void)?
    private var reason: FinishReason?
    let work = NotificationRequestWork()

    init(initial: Content, handler: @escaping (Content) -> Void) {
        self.content = initial
        self.handler = handler
    }

    var isPending: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.handler != nil
    }

    var finishReason: FinishReason? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.reason
    }

    @discardableResult
    func update(_ content: Content) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.handler != nil else { return false }
        self.content = content
        return true
    }

    @discardableResult
    func finish(reason: FinishReason = .completed) -> Bool {
        self.lock.lock()
        guard let handler = self.handler, let content = self.content else {
            self.lock.unlock()
            return false
        }
        self.handler = nil
        self.content = nil
        self.reason = reason
        self.lock.unlock()
        self.work.cancel()
        handler(content)
        return true
    }
}

/// Several pushes can be in flight in one extension instance. Arrival of a new
/// push must not finish the preceding request with its fallback.
final class NotificationRequestRegistry<Content>: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [UUID: NotificationRequestCompletion<Content>] = [:]

    func insert(_ request: NotificationRequestCompletion<Content>, id: UUID) {
        self.lock.lock()
        self.requests[id] = request
        self.lock.unlock()
    }

    func remove(id: UUID) {
        self.lock.lock()
        self.requests.removeValue(forKey: id)
        self.lock.unlock()
    }

    func takeAll() -> [NotificationRequestCompletion<Content>] {
        self.lock.lock()
        let values = Array(self.requests.values)
        self.requests.removeAll()
        self.lock.unlock()
        return values
    }
}
