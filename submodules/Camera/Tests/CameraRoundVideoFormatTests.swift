import XCTest
#if SWIFT_PACKAGE
@testable import Camera
#endif

final class CameraRoundVideoFormatTests: XCTestCase {
    private func format(_ index: Int, _ width: Int32, _ height: Int32, _ ranges: [ClosedRange<Double>], multiCam: Bool = true, yuv: Bool = true) -> CameraRoundVideoFormat {
        CameraRoundVideoFormat(index: index, width: width, height: height, isVideoRange420: yuv, supportsMultiCam: multiCam, frameRateRanges: ranges)
    }

    private func select(_ formats: [CameraRoundVideoFormat], multiCam: Bool = false) -> Int? {
        cameraPreferredRoundVideoFormat(formats: formats, maxWidth: 1920, maxHeight: 1440, requiresMultiCam: multiCam)
    }

    func testSixtyFpsBeatsHigherResolutionThirtyFps() {
        XCTAssertEqual(self.select([self.format(0, 1920, 1440, [1 ... 30]), self.format(1, 1280, 960, [1 ... 60])]), 1)
    }

    func testFormatWithHighSpeedRangeIsNotRejected() {
        XCTAssertEqual(self.select([self.format(0, 1920, 1080, [1 ... 240]), self.format(1, 1920, 1080, [1 ... 30])]), 0)
    }

    func testAllRangesParticipateAndOrderDoesNotChangeSelection() {
        let formats = [self.format(5, 1280, 720, [1 ... 30, 60 ... 60]), self.format(6, 1280, 720, [1 ... 30])]
        XCTAssertEqual(self.select(formats), 5)
        XCTAssertEqual(self.select(Array(formats.reversed())), 5)
    }

    func testMultiCamRequiresSupportedFormat() {
        XCTAssertEqual(self.select([self.format(0, 1920, 1080, [1 ... 60], multiCam: false), self.format(1, 640, 480, [1 ... 60])], multiCam: true), 1)
    }

    func testUnsupportedHardwareFallsBackToNearestCadence() {
        XCTAssertEqual(self.select([self.format(0, 640, 480, [1 ... 24]), self.format(1, 640, 480, [1 ... 30])]), 1)
        XCTAssertNil(self.select([]))
        XCTAssertNil(self.select([self.format(0, 3840, 2160, [1 ... 60]), self.format(1, 640, 480, [1 ... 60], yuv: false)]))
    }
}
