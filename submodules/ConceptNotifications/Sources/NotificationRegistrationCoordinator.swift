import Foundation
import SwiftSignalKit

public struct NotificationRegistrationKey: Hashable {
    public let accountId: Int64
    public let channel: String
    public init(accountId: Int64, channel: String) { self.accountId = accountId; self.channel = channel }
}

public struct NotificationRegistrationRequest {
    public let key: NotificationRegistrationKey
    /// Stable server-side token identity, without account preferences.
    public let credential: Data
    /// Includes token, environment, other accounts and relevant preferences.
    public let fingerprint: Data
    public let register: () -> Signal<NotificationRegistrationResult, NoError>
    public let unregister: () -> Signal<Never, NoError>

    public init(key: NotificationRegistrationKey, credential: Data, fingerprint: Data, register: @escaping () -> Signal<NotificationRegistrationResult, NoError>, unregister: @escaping () -> Signal<Never, NoError>) {
        self.key = key; self.credential = credential; self.fingerprint = fingerprint
        self.register = register; self.unregister = unregister
    }
}

/// One serialized owner for each account/channel. Account/preference changes do
/// not create independent subscriptions that can unregister a replacement token.
public final class NotificationRegistrationCoordinator {
    public static let retryRequested = Notification.Name("Concept.NotificationRegistrationRetryRequested")
    private enum Phase {
        case idle
        case registering(UUID, NotificationRegistrationRequest)
        case cleaning(UUID)
        case waiting(UUID)
    }
    private final class Lane {
        let key: NotificationRegistrationKey
        var desired: NotificationRegistrationRequest?
        var registered: NotificationRegistrationRequest?
        var retired: [NotificationRegistrationRequest] = []
        var phase: Phase = .idle
        var failedFingerprint: Data?
        var refresh = false
        var attempts = 0
        var timer: SwiftSignalKit.Timer?
        let work = MetaDisposable()
        init(key: NotificationRegistrationKey) { self.key = key }
        deinit { self.timer?.invalidate(); self.work.dispose() }
    }
    private let queue: Queue
    private let registrationTimeout: Double
    private let cleanupTimeout: Double
    private let event: (NotificationRegistrationKey, NotificationRegistrationResult) -> Void
    private var lanes: [NotificationRegistrationKey: Lane] = [:]

    public init(queue: Queue = .mainQueue(), registrationTimeout: Double = 15.0, cleanupTimeout: Double = 10.0, event: @escaping (NotificationRegistrationKey, NotificationRegistrationResult) -> Void) {
        self.queue = queue
        self.registrationTimeout = registrationTimeout
        self.cleanupTimeout = cleanupTimeout
        self.event = event
    }

    public func reset() {
        self.queue.justDispatch { self.lanes.removeAll() }
    }

    public func update(_ requests: [NotificationRegistrationRequest]) {
        self.queue.justDispatch {
            let desired = Dictionary(requests.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
            for (key, lane) in self.lanes where desired[key] == nil {
                lane.desired = nil
                self.cancelRetry(lane)
            }
            for (key, request) in desired {
                let lane = self.lanes[key] ?? Lane(key: key)
                self.lanes[key] = lane
                if lane.desired?.fingerprint != request.fingerprint {
                    self.cancelRetry(lane)
                    lane.failedFingerprint = nil
                    lane.attempts = 0
                }
                lane.desired = request
            }
            for lane in Array(self.lanes.values) { self.drive(lane) }
        }
    }

    /// Called on an explicit retry or foreground/network recovery, not on every
    /// unrelated state emission. Permanent server errors otherwise remain visible.
    public func refresh() {
        self.queue.justDispatch {
            for lane in Array(self.lanes.values) where lane.desired != nil {
                self.cancelRetry(lane)
                lane.failedFingerprint = nil
                lane.refresh = true
                self.drive(lane)
            }
        }
    }

    public func retire(_ request: NotificationRegistrationRequest) {
        self.queue.justDispatch {
            let lane = self.lanes[request.key] ?? Lane(key: request.key)
            self.lanes[request.key] = lane
            if !lane.retired.contains(where: { $0.credential == request.credential }) {
                lane.retired.append(request)
            }
            self.drive(lane)
        }
    }

    private func cancelRetry(_ lane: Lane) {
        if case .waiting = lane.phase {
            lane.timer?.invalidate(); lane.timer = nil
            lane.phase = .idle
        }
    }

    private func drive(_ lane: Lane) {
        guard case .idle = lane.phase else { return }
        if let desired = lane.desired {
            if lane.failedFingerprint != desired.fingerprint, lane.registered?.fingerprint != desired.fingerprint || lane.refresh {
                self.register(desired, lane: lane)
                return
            }
        } else if let registered = lane.registered {
            lane.retired.append(registered)
            lane.registered = nil
        }
        if !lane.retired.isEmpty {
            let retired = lane.retired.removeFirst()
            // Never unregister the same token that has just been registered
            // with new preferences. Its server identity is unchanged.
            if lane.desired?.credential == retired.credential {
                self.drive(lane)
            } else {
                self.clean(retired, lane: lane)
            }
        } else if lane.desired == nil, lane.registered == nil {
            self.lanes.removeValue(forKey: lane.key)
        }
    }

    private func register(_ request: NotificationRegistrationRequest, lane: Lane) {
        let id = UUID()
        lane.phase = .registering(id, request)
        lane.refresh = false
        lane.attempts += 1
        let work = MetaDisposable()
        lane.work.set(work)
        var emitted = false
        work.set((request.register()
        |> timeout(self.registrationTimeout, queue: self.queue, alternate: .single(.failed(code: "REGISTRATION_TIMEOUT", retryAfter: 1.0)))
        |> take(1)
        |> deliverOn(self.queue)).start(next: { [weak self, weak lane] result in
            guard let self, let lane else { return }
            emitted = true
            self.finished(result, request: request, id: id, lane: lane)
        }, completed: { [weak self, weak lane] in
            guard !emitted, let self, let lane else { return }
            self.finished(.failed(code: "EMPTY_REGISTRATION_RESPONSE", retryAfter: 1.0), request: request, id: id, lane: lane)
        }))
    }

    private func finished(_ result: NotificationRegistrationResult, request: NotificationRegistrationRequest, id: UUID, lane: Lane) {
        guard case let .registering(active, _) = lane.phase, active == id else { return }
        lane.phase = .idle
        lane.work.set(nil)
        if result == .registered {
            if let previous = lane.registered, previous.credential != request.credential { lane.retired.append(previous) }
            lane.registered = request
            lane.failedFingerprint = nil
            lane.attempts = 0
        }
        let stillDesired = lane.desired?.fingerprint == request.fingerprint
        if stillDesired {
            self.event(request.key, result)
            switch result {
            case .registered: break
            case .tokenInvalidated: lane.failedFingerprint = request.fingerprint
            case let .failed(_, retryAfter):
                if let retryAfter {
                    lane.refresh = true
                    let delay = max(retryAfter, Self.retryDelay(attempt: lane.attempts))
                    let timerId = UUID()
                    lane.phase = .waiting(timerId)
                    let timer = SwiftSignalKit.Timer(timeout: delay, repeat: false, completion: { [weak self, weak lane] in
                        guard let self, let lane, case let .waiting(active) = lane.phase, active == timerId else { return }
                        lane.timer = nil; lane.phase = .idle
                        self.drive(lane)
                    }, queue: self.queue)
                    lane.timer = timer
                    timer.start()
                    return
                } else {
                    lane.failedFingerprint = request.fingerprint
                }
            }
        } else if result != .registered, lane.desired?.credential != request.credential {
            // A timed-out request might still have reached Telegram. Retire its
            // server identity as well when this account/token is no longer used.
            lane.retired.append(request)
        }
        self.drive(lane)
    }

    private func clean(_ request: NotificationRegistrationRequest, lane: Lane) {
        let id = UUID()
        lane.phase = .cleaning(id)
        let work = MetaDisposable()
        lane.work.set(work)
        work.set((request.unregister()
        |> timeout(self.cleanupTimeout, queue: self.queue, alternate: .complete())
        |> deliverOn(self.queue)).start(completed: { [weak self, weak lane] in
            guard let self, let lane, case let .cleaning(active) = lane.phase, active == id else { return }
            lane.phase = .idle
            lane.work.set(nil)
            self.drive(lane)
        }))
    }

    public static func retryDelay(attempt: Int) -> TimeInterval {
        return min(300.0, pow(2.0, Double(max(0, min(9, attempt - 1)))))
    }
}
