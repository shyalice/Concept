import XCTest
#if SWIFT_PACKAGE
@testable import Camera
#endif

final class CameraFrameRateTests: XCTestCase {
    func testSixtyFpsCanBeInALaterRange() {
        XCTAssertEqual(cameraClosestSupportedFrameRate(requested: 60, ranges: [1 ... 30, 30 ... 60]), 60)
    }

    func testOlderFormatFallsBackToThirty() {
        XCTAssertEqual(cameraClosestSupportedFrameRate(requested: 60, ranges: [1 ... 30]), 30)
    }

    func testRequestedRateBelowFormatMinimumIsClamped() {
        XCTAssertEqual(cameraClosestSupportedFrameRate(requested: 30, ranges: [60 ... 120]), 60)
    }

    func testInvalidRateAndMissingFormatsAreRejected() {
        XCTAssertNil(cameraClosestSupportedFrameRate(requested: .nan, ranges: [1 ... 60]))
        XCTAssertNil(cameraClosestSupportedFrameRate(requested: .infinity, ranges: [1 ... 60]))
        XCTAssertNil(cameraClosestSupportedFrameRate(requested: 0, ranges: [1 ... 60]))
        XCTAssertNil(cameraClosestSupportedFrameRate(requested: 60, ranges: []))
    }
}
