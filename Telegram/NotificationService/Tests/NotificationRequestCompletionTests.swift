import Foundation
import XCTest
@testable import NotificationServiceExtensionLib

final class NotificationRequestCompletionTests: XCTestCase {
    func testExpiryAfterFetchDoesNotCompleteTwice() {
        var delivered: [String] = []
        let request = NotificationRequestCompletion(initial: "fallback", handler: { delivered.append($0) })
        XCTAssertTrue(request.update("resolved"))
        XCTAssertTrue(request.finish())
        XCTAssertFalse(request.finish())
        XCTAssertFalse(request.update("late"))
        XCTAssertEqual(delivered, ["resolved"])
    }

    func testFetchAfterExpiryCannotChangeDeliveredFallback() {
        var delivered: [String] = []
        let request = NotificationRequestCompletion(initial: "fallback", handler: { delivered.append($0) })
        XCTAssertTrue(request.finish())
        XCTAssertFalse(request.update("resolved too late"))
        XCTAssertFalse(request.finish())
        XCTAssertEqual(delivered, ["fallback"])
    }

    func testConsecutiveRequestsKeepSeparateSnapshots() {
        var delivered: [String] = []
        let first = NotificationRequestCompletion(initial: "first", handler: { delivered.append($0) })
        first.update("first resolved")
        first.finish()
        let second = NotificationRequestCompletion(initial: "second", handler: { delivered.append($0) })
        first.update("stale result")
        second.finish()
        XCTAssertEqual(delivered, ["first resolved", "second"])
    }
}
