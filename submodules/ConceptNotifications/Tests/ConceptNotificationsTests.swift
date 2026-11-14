import Foundation
import XCTest
import SwiftSignalKit
@testable import ConceptNotifications

final class ConceptNotificationsTests: XCTestCase {
    func testExactlyOnceCallbackAcrossConcurrentTimeouts() {
        let lock = NSLock()
        var values: [Int] = []
        let once = NotificationOnceCompletion<Int> { value in lock.lock(); values.append(value); lock.unlock() }
        DispatchQueue.concurrentPerform(iterations: 200) { value in once.finish(value) }
        XCTAssertEqual(values.count, 1)
        XCTAssertFalse(once.finish(999))
    }

    func testAuthorizationCoalescesOnboardingAndStartupAndCompletesEveryCaller() {
        let queue = Queue(name: "notification.auth.test")
        var readCallback: ((NotificationAuthorizationState) -> Void)?
        var requestCallback: ((Bool) -> Void)?
        var prompts = 0
        let coordinator = NotificationAuthorizationCoordinator(queue: queue, read: { readCallback = $0 }, request: { prompts += 1; requestCallback = $0 }, isForeground: { true })
        let finished = expectation(description: "all permission consumers")
        finished.expectedFulfillmentCount = 3
        coordinator.ensure(allowsPrompt: false) { XCTAssertTrue($0); finished.fulfill() }
        coordinator.ensure(allowsPrompt: true) { XCTAssertTrue($0); finished.fulfill() }
        coordinator.ensure(allowsPrompt: true) { XCTAssertTrue($0); finished.fulfill() }
        queue.sync { readCallback?(.notDetermined) }
        queue.sync { XCTAssertEqual(prompts, 1); requestCallback?(true); requestCallback?(false) }
        wait(for: [finished], timeout: 2)
    }

    func testDeniedAndUnpromptedPermissionAlwaysCompleteWithoutPrompt() {
        for status in [NotificationAuthorizationState.denied, .notDetermined, .authorized, .provisional, .ephemeral] {
            let done = expectation(description: "permission \(status)")
            let coordinator = NotificationAuthorizationCoordinator(queue: Queue(name: "permission.result"), read: { $0(status) }, request: { _ in XCTFail("unexpected prompt") }, isForeground: { true })
            coordinator.ensure(allowsPrompt: false) { XCTAssertEqual($0, status.permitsNotifications); done.fulfill() }
            wait(for: [done], timeout: 2)
            withExtendedLifetime(coordinator) {}
        }
    }

    func testBackgroundCannotTriggerPermissionDialog() {
        let done = expectation(description: "background permission")
        let coordinator = NotificationAuthorizationCoordinator(queue: Queue(name: "permission.background"), read: { $0(.notDetermined) }, request: { _ in XCTFail("background prompt") }, isForeground: { false })
        coordinator.ensure(allowsPrompt: true) { XCTAssertFalse($0); done.fulfill() }
        wait(for: [done], timeout: 2)
        withExtendedLifetime(coordinator) {}
    }

    func testPermanentErrorsDoNotBecomeSuccessOrSpinInvalidation() {
        XCTAssertEqual(NotificationRegistrationResult.failure(code: "APP_PUSH_CERT_MISSING", status: 400), .failed(code: "APP_PUSH_CERT_MISSING", retryAfter: nil))
        XCTAssertEqual(NotificationRegistrationResult.failure(code: "TOKEN_WAS_INVALIDATED", status: 400), .tokenInvalidated)
        XCTAssertEqual(NotificationRegistrationResult.failure(code: "FLOOD_WAIT_3600", status: 420), .failed(code: "FLOOD_WAIT_3600", retryAfter: 3600))
        XCTAssertEqual(NotificationRegistrationResult.failure(code: "TIMEOUT", status: -1), .failed(code: "TIMEOUT", retryAfter: 1))
    }

    func testRegistrationSerializesRemovalAndReaddition() {
        let queue = Queue(name: "registration.serial")
        let registered = expectation(description: "registered twice")
        registered.expectedFulfillmentCount = 2
        var cleanupCompletion: (() -> Void)?
        var starts = 0
        let request = NotificationRegistrationRequest(key: .init(accountId: 1, channel: "aps"), credential: Data([1]), fingerprint: Data([1]), register: { starts += 1; return .single(.registered) }, unregister: {
            return Signal { subscriber in cleanupCompletion = { subscriber.putCompletion() }; return EmptyDisposable }
        })
        let coordinator = NotificationRegistrationCoordinator(queue: queue, event: { _, result in XCTAssertEqual(result, .registered); registered.fulfill() })
        coordinator.update([request]); queue.sync {}
        coordinator.update([]); queue.sync {}
        coordinator.update([request]); queue.sync { XCTAssertEqual(starts, 1); cleanupCompletion?() }
        wait(for: [registered], timeout: 2)
        withExtendedLifetime(coordinator) {}
    }

    func testPreferenceChangesDoNotUnregisterIdenticalCredential() {
        let queue = Queue(name: "registration.preferences")
        let events = expectation(description: "both preferences registered"); events.expectedFulfillmentCount = 2
        var removed = 0
        func request(_ version: UInt8) -> NotificationRegistrationRequest {
            return NotificationRegistrationRequest(key: .init(accountId: 1, channel: "aps"), credential: Data([1]), fingerprint: Data([version]), register: { .single(.registered) }, unregister: { removed += 1; return .complete() })
        }
        let coordinator = NotificationRegistrationCoordinator(queue: queue, event: { _, _ in events.fulfill() })
        coordinator.update([request(1)]); queue.sync {}
        coordinator.update([request(2)]); queue.sync {}
        wait(for: [events], timeout: 2)
        queue.sync { XCTAssertEqual(removed, 0) }
        withExtendedLifetime(coordinator) {}
    }

    func testPermanentFailureRetriesOnlyWhenExplicitlyRefreshed() {
        let queue = Queue(name: "registration.failure")
        let events = expectation(description: "initial and explicit retry"); events.expectedFulfillmentCount = 2
        var attempts = 0
        let request = NotificationRegistrationRequest(key: .init(accountId: 1, channel: "aps"), credential: Data([1]), fingerprint: Data([1]), register: { attempts += 1; return .single(.failed(code: "APP_PUSH_CERT_MISSING", retryAfter: nil)) }, unregister: { .complete() })
        let coordinator = NotificationRegistrationCoordinator(queue: queue, event: { _, result in XCTAssertEqual(result, .failed(code: "APP_PUSH_CERT_MISSING", retryAfter: nil)); events.fulfill() })
        coordinator.update([request]); queue.sync {}
        coordinator.update([request]); queue.sync { XCTAssertEqual(attempts, 1) }
        coordinator.refresh(); queue.sync {}
        wait(for: [events], timeout: 2)
        withExtendedLifetime(coordinator) {}
    }

    func testMissingRPCResultTimesOutAndDoesNotLeakWork() {
        let disposed = expectation(description: "hung RPC cancelled")
        let result = expectation(description: "real timeout failure")
        let queue = Queue(name: "registration.timeout")
        let request = NotificationRegistrationRequest(key: .init(accountId: 1, channel: "aps"), credential: Data([1]), fingerprint: Data([1]), register: { Signal { _ in ActionDisposable { disposed.fulfill() } } }, unregister: { .complete() })
        let coordinator = NotificationRegistrationCoordinator(queue: queue, registrationTimeout: 0.03, event: { _, value in XCTAssertEqual(value, .failed(code: "REGISTRATION_TIMEOUT", retryAfter: 1)); result.fulfill() })
        coordinator.update([request])
        wait(for: [result, disposed], timeout: 2)
        coordinator.update([]); queue.sync {}
        withExtendedLifetime(coordinator) {}
    }
}

final class NotificationDeliveryCommitTests: XCTestCase {
    func testNormalDisposalDoesNotCancelSuccessfulHandoff() {
        let delivery = NotificationDeliveryCommit()
        XCTAssertTrue(delivery.commit())
        XCTAssertFalse(delivery.cancel())
        XCTAssertFalse(delivery.commit())
    }
    func testExpiryRejectsLateSystemCallback() {
        let delivery = NotificationDeliveryCommit()
        XCTAssertTrue(delivery.cancel())
        XCTAssertFalse(delivery.commit())
        XCTAssertFalse(delivery.cancel())
    }
    func testConcurrentExpiryAndHandoffHaveOneOwner() {
        for _ in 0..<100 {
            let delivery = NotificationDeliveryCommit()
            let lock = NSLock()
            var owners = 0
            DispatchQueue.concurrentPerform(iterations: 32) { index in
                let won = index % 2 == 0 ? delivery.commit() : delivery.cancel()
                if won { lock.lock(); owners += 1; lock.unlock() }
            }
            XCTAssertEqual(owners, 1)
        }
    }
}

final class NotificationAccountSubscriptionsTests: XCTestCase {
    private final class Account {
        let events = ValuePipe<Int>()
    }

    func testTwoAccountsKeepDeliveringWhenPrimarySelectionChanges() {
        let petya = Account()
        let vasya = Account()
        let registry = NotificationAccountSubscriptions<Int>()
        let accounts = [1: petya, 2: vasya]
        var received: [Int] = []
        var subscriptions = 0
        let subscribe: (Int) -> Disposable = { id in
            subscriptions += 1
            return accounts[id]!.events.signal().start(next: { _ in received.append(id) })
        }
        registry.update(accounts.mapValues(ObjectIdentifier.init), subscribe: subscribe)
        // Reordering around another selected primary must retain both subscriptions.
        registry.update([2: ObjectIdentifier(vasya), 1: ObjectIdentifier(petya)], subscribe: subscribe)
        petya.events.putNext(1)
        vasya.events.putNext(1)
        XCTAssertEqual(received, [1, 2])
        XCTAssertEqual(subscriptions, 2)
        registry.dispose()
        petya.events.putNext(2)
        XCTAssertEqual(received, [1, 2])
    }

    func testRemovedAndRecreatedAccountsReleaseTheirOldStreams() {
        let old = Account()
        let replacement = Account()
        let registry = NotificationAccountSubscriptions<Int>()
        var received: [String] = []
        registry.update([1: ObjectIdentifier(old)], subscribe: { _ in
            old.events.signal().start(next: { _ in received.append("old") })
        })
        registry.update([1: ObjectIdentifier(replacement)], subscribe: { _ in
            replacement.events.signal().start(next: { _ in received.append("replacement") })
        })
        old.events.putNext(1)
        replacement.events.putNext(1)
        XCTAssertEqual(received, ["replacement"])
        registry.update([:], subscribe: { _ in XCTFail("Removed account subscribed"); return EmptyDisposable })
        replacement.events.putNext(2)
        XCTAssertEqual(received, ["replacement"])
    }
}
