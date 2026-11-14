import Foundation
import XCTest
@testable import CaptureObserverHost

final class CaptureNotificationObserverTests: XCTestCase {
    private let captureName = Notification.Name("Concept.TestCapture")

    func testRepeatSuppressionIsPerObserver() {
        let center = NotificationCenter()
        var first = 0
        var second = 0
        let a = CaptureNotificationObserver(center: center, name: captureName, repeatInterval: 0.5) { first += 1 }
        let b = CaptureNotificationObserver(center: center, name: captureName, repeatInterval: 0.5) { second += 1 }
        center.post(name: captureName, object: nil)
        center.post(name: captureName, object: nil)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1)
        withExtendedLifetime((a, b)) {}
    }

    func testClearIsIdempotentAndStopsDelivery() {
        let center = NotificationCenter()
        var count = 0
        let observer = CaptureNotificationObserver(center: center, name: captureName, repeatInterval: 0) { count += 1 }
        center.post(name: captureName, object: nil)
        observer.clear()
        observer.clear()
        center.post(name: captureName, object: nil)
        XCTAssertEqual(count, 1)
    }

    func testBackgroundCaptureDoesNotCarryNotificationPayloadToMainQueue() {
        final class Payload: NSObject {}
        let center = NotificationCenter()
        let delivered = expectation(description: "capture delivered on main")
        let posted = DispatchSemaphore(value: 0)
        weak var payload: Payload?
        let observer = CaptureNotificationObserver(center: center, name: captureName, repeatInterval: 0) {
            XCTAssertTrue(Thread.isMainThread)
            delivered.fulfill()
        }
        let eventName = self.captureName
        DispatchQueue.global().async {
            autoreleasepool {
                let value = Payload()
                payload = value
                center.post(name: eventName, object: value, userInfo: ["capture": value])
            }
            posted.signal()
        }
        XCTAssertEqual(posted.wait(timeout: .now() + 2), .success)
        XCTAssertNil(payload, "Only the capture event, never its notification payload, crosses the queue")
        wait(for: [delivered], timeout: 2)
        withExtendedLifetime(observer) {}
    }

    func testClearDropsAlreadyQueuedCapture() {
        let center = NotificationCenter()
        let posted = DispatchSemaphore(value: 0)
        let drained = expectation(description: "main queue drained")
        var count = 0
        let observer = CaptureNotificationObserver(center: center, name: captureName, repeatInterval: 0) { count += 1 }
        let eventName = self.captureName
        DispatchQueue.global().async {
            center.post(name: eventName, object: nil)
            posted.signal()
        }
        XCTAssertEqual(posted.wait(timeout: .now() + 2), .success)
        observer.clear()
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(count, 0)
    }

    func testObserverDoesNotRetainItself() {
        let center = NotificationCenter()
        weak var released: CaptureNotificationObserver?
        autoreleasepool {
            let observer = CaptureNotificationObserver(center: center, name: captureName, repeatInterval: 0) {}
            released = observer
        }
        XCTAssertNil(released)
        center.post(name: captureName, object: nil)
    }
}
