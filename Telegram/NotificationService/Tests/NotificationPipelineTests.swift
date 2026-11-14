import Foundation
import XCTest
import SwiftSignalKit
@testable import NotificationServiceExtensionLib

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        self.lock.lock()
        self.values.append(value)
        self.lock.unlock()
    }

    var snapshot: [Value] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values
    }
}

final class NotificationPipelineTests: XCTestCase {
    func testFinishingCancelsEveryOperationBeforeDelivery() {
        let events = LockedValues<String>()
        let request = NotificationRequestCompletion(initial: "fallback", handler: { events.append($0) })
        request.work.addCancellation { events.append("cancel download") }
        request.work.addCancellation { events.append("close connection") }
        request.update("decrypted")
        XCTAssertTrue(request.finish(reason: .systemExpiry))
        XCTAssertFalse(request.finish())
        XCTAssertEqual(request.finishReason, .systemExpiry)
        XCTAssertEqual(events.snapshot, ["cancel download", "close connection", "decrypted"])
    }

    func testOperationRegisteredAfterExpiryIsCancelledImmediately() {
        let events = LockedValues<String>()
        let request = NotificationRequestCompletion(initial: "fallback", handler: { events.append($0) })
        request.finish(reason: .deadline)
        request.work.addCancellation { events.append("late operation cancelled") }
        XCTAssertEqual(request.finishReason, .deadline)
        XCTAssertFalse(request.update("late result"))
        XCTAssertEqual(events.snapshot, ["fallback", "late operation cancelled"])
    }

    func testCancellationCanReenterWithoutHoldingTheLock() {
        let events = LockedValues<String>()
        let request = NotificationRequestCompletion(initial: "fallback", handler: { events.append($0) })
        request.work.addCancellation {
            request.work.cancel()
            request.work.addCancellation { events.append("nested cancellation") }
            XCTAssertFalse(request.finish())
        }
        request.finish()
        XCTAssertEqual(events.snapshot, ["nested cancellation", "fallback"])
    }

    func testConcurrentRegistrationAndExpiryCancelEachOperationOnce() {
        let cancelled = LockedValues<Int>()
        let request = NotificationRequestCompletion(initial: "fallback", handler: { _ in })
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            request.work.addCancellation { cancelled.append(index) }
            if index.isMultiple(of: 7) { request.finish(reason: .deadline) }
        }
        request.finish()
        XCTAssertEqual(cancelled.snapshot.sorted(), Array(0 ..< 200))
    }

    func testSynchronousSignalCompletionCancelsDisposableReturnedAfterFinish() {
        var disposed = 0
        let request = NotificationRequestCompletion(initial: "fallback", handler: { _ in })
        let signal = Signal<Int, NoError> { subscriber in
            subscriber.putNext(42)
            subscriber.putCompletion()
            return ActionDisposable { disposed += 1 }
        }
        let _ = signal.start(request: request.work, next: { request.update("\($0)") }, completed: { request.finish() })
        XCTAssertEqual(disposed, 1)
        XCTAssertFalse(request.isPending)
    }

    func testExpiredRequestDoesNotStartAnotherSignalGenerator() {
        var started = false
        let request = NotificationRequestCompletion(initial: "fallback", handler: { _ in })
        request.finish()
        let signal = Signal<Int, NoError> { _ in
            started = true
            return EmptyDisposable
        }
        let _ = signal.start(request: request.work)
        XCTAssertFalse(started)
    }

    func testLateSignalEventsCannotChangeDeliveredSnapshot() {
        var subscriber: Subscriber<Int, NoError>?
        var delivered: [String] = []
        let request = NotificationRequestCompletion(initial: "fallback", handler: { delivered.append($0) })
        let signal = Signal<Int, NoError> { value in
            subscriber = value
            return EmptyDisposable
        }
        let _ = signal.start(request: request.work, next: { request.update("\($0)") }, completed: { request.finish() })
        request.finish(reason: .systemExpiry)
        subscriber?.putNext(42)
        subscriber?.putCompletion()
        XCTAssertEqual(delivered, ["fallback"])
    }

    func testASecondPushKeepsTheFirstPushAlive() {
        var delivered: [String] = []
        let registry = NotificationRequestRegistry<String>()
        let firstId = UUID(), secondId = UUID()
        let first = NotificationRequestCompletion(initial: "first", handler: { delivered.append($0) })
        let second = NotificationRequestCompletion(initial: "second", handler: { delivered.append($0) })
        registry.insert(first, id: firstId)
        registry.insert(second, id: secondId)
        XCTAssertTrue(first.isPending)
        XCTAssertTrue(second.isPending)
        first.update("first resolved")
        first.finish()
        registry.remove(id: firstId)
        XCTAssertTrue(second.isPending)
        let remaining = registry.takeAll()
        XCTAssertEqual(remaining.count, 1)
        remaining.forEach { $0.finish(reason: .systemExpiry) }
        XCTAssertEqual(delivered, ["first resolved", "second"])
    }

    func testSystemExpiryDrainsEveryPendingPushOnce() {
        let delivered = LockedValues<Int>()
        let registry = NotificationRequestRegistry<Int>()
        for index in 0 ..< 20 {
            registry.insert(NotificationRequestCompletion(initial: index, handler: delivered.append), id: UUID())
        }
        let requests = registry.takeAll()
        requests.forEach { $0.finish(reason: .systemExpiry) }
        requests.forEach { $0.finish() }
        XCTAssertTrue(registry.takeAll().isEmpty)
        XCTAssertEqual(delivered.snapshot.sorted(), Array(0 ..< 20))
    }

    func testPreparationAndDownloadsConsumeTheSameBudget() {
        var uptime: TimeInterval = 100
        let budget = NotificationExecutionBudget(now: { uptime })
        uptime += 8 // queue/database/decryption
        XCTAssertEqual(budget.remaining(maximum: 15), 15)
        uptime += 14 // state synchronization
        XCTAssertEqual(budget.remaining(maximum: 10), 3)
        uptime += 4
        XCTAssertEqual(budget.remaining(), 0)
        XCTAssertEqual(budget.remaining(maximum: 5), 0)
    }

    func testDeliveryWaitsForItsPersistenceBarrier() {
        var transaction: Subscriber<Never, NoError>?
        var delivered: [String] = []
        let request = NotificationRequestCompletion(initial: "fallback", handler: { delivered.append($0) })
        let persistence = Signal<Never, NoError> { subscriber in
            transaction = subscriber
            return EmptyDisposable
        }
        request.update("decrypted")
        let _ = persistence.start(request: request.work, completed: { request.finish() })
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(request.isPending)
        transaction?.putCompletion()
        XCTAssertEqual(delivered, ["decrypted"])
        XCTAssertFalse(request.isPending)
    }

    func testExpiryCancelsAContendedPersistenceBarrierAndUsesTheSnapshot() {
        var transaction: Subscriber<Never, NoError>?
        var wasCancelled = false
        var delivered: [String] = []
        let request = NotificationRequestCompletion(initial: "fallback", handler: { delivered.append($0) })
        let persistence = Signal<Never, NoError> { subscriber in
            transaction = subscriber
            return ActionDisposable { wasCancelled = true }
        }
        request.update("decrypted")
        let _ = persistence.start(request: request.work, completed: { request.finish() })
        request.finish(reason: .deadline)
        XCTAssertTrue(wasCancelled)
        transaction?.putCompletion()
        XCTAssertEqual(delivered, ["decrypted"])
        XCTAssertEqual(request.finishReason, .deadline)
    }

    func testInvalidAccountIdentityDoesNotClearOtherAccounts() {
        XCTAssertTrue(notificationBelongsToAccount(["accountId": "123"], accountId: 123))
        XCTAssertTrue(notificationBelongsToAccount(["accountId": NSNumber(value: 123)], accountId: 123))
        XCTAssertFalse(notificationBelongsToAccount(["accountId": "124"], accountId: 123))
        XCTAssertFalse(notificationBelongsToAccount(["accountId": "invalid"], accountId: 123))
        XCTAssertFalse(notificationBelongsToAccount(["peerId": "123"], accountId: 123))
    }
}
