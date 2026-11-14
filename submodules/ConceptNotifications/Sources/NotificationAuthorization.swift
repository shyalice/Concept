import Foundation
import SwiftSignalKit

public enum NotificationAuthorizationState: Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    public var permitsNotifications: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined, .denied: return false
        }
    }
}

/// Shared by automatic startup and explicit settings/onboarding requests. UIKit
/// lives in the adapter; the actual lifecycle is tested with the same coordinator.
public final class NotificationAuthorizationCoordinator {
    private struct Request {
        let allowsPrompt: Bool
        let completion: (Bool) -> Void
    }
    private let queue: Queue
    private let read: (@escaping (NotificationAuthorizationState) -> Void) -> Void
    private let request: (@escaping (Bool) -> Void) -> Void
    private let isForeground: () -> Bool
    private var pending: [Request] = []
    private var checking = false
    private var prompting = false
    private var generation: UInt64 = 0

    public init(queue: Queue = .mainQueue(), read: @escaping (@escaping (NotificationAuthorizationState) -> Void) -> Void, request: @escaping (@escaping (Bool) -> Void) -> Void, isForeground: @escaping () -> Bool) {
        self.queue = queue
        self.read = read
        self.request = request
        self.isForeground = isForeground
    }

    public func ensure(allowsPrompt: Bool, completion: @escaping (Bool) -> Void) {
        self.queue.async {
            self.pending.append(Request(allowsPrompt: allowsPrompt, completion: completion))
            guard !self.checking else { return }
            self.checking = true
            self.generation &+= 1
            let generation = self.generation
            self.queue.after(5.0) { [weak self] in
                guard let self, self.checking, !self.prompting, self.generation == generation else { return }
                self.finish(false)
            }
            let once = NotificationOnceCompletion<NotificationAuthorizationState> { [weak self] state in
                guard let self else { return }
                self.queue.async {
                    guard self.checking, self.generation == generation else { return }
                    self.received(state, generation: generation)
                }
            }
            self.read { once.finish($0) }
        }
    }

    private func received(_ state: NotificationAuthorizationState, generation: UInt64) {
        if state == .notDetermined, self.pending.contains(where: { $0.allowsPrompt }), self.isForeground() {
            self.prompting = true
            let once = NotificationOnceCompletion<Bool> { [weak self] granted in
                guard let self else { return }
                self.queue.async {
                    guard self.checking, self.generation == generation else { return }
                    self.finish(granted)
                }
            }
            self.request { once.finish($0) }
        } else {
            self.finish(state.permitsNotifications)
        }
    }

    private func finish(_ result: Bool) {
        let requests = self.pending
        self.pending.removeAll()
        self.checking = false
        self.prompting = false
        for request in requests { request.completion(result) }
    }
}

/// Framework callbacks can race a timeout or a second callback. Never call a
/// system handler twice, and never run arbitrary handlers while holding a lock.
public final class NotificationOnceCompletion<Value> {
    private let lock = NSLock()
    private var handler: ((Value) -> Void)?

    public init(_ handler: @escaping (Value) -> Void) { self.handler = handler }

    @discardableResult public func finish(_ value: Value) -> Bool {
        self.lock.lock()
        let handler = self.handler
        self.handler = nil
        self.lock.unlock()
        guard let handler else { return false }
        handler(value)
        return true
    }
}
