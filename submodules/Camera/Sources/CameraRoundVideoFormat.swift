import Foundation

public struct CameraRoundVideoFormat {
    public let index: Int
    public let width: Int32
    public let height: Int32
    public let isVideoRange420: Bool
    public let supportsMultiCam: Bool
    public let frameRateRanges: [ClosedRange<Double>]

    public init(index: Int, width: Int32, height: Int32, isVideoRange420: Bool, supportsMultiCam: Bool, frameRateRanges: [ClosedRange<Double>]) {
        self.index = index
        self.width = width
        self.height = height
        self.isVideoRange420 = isVideoRange420
        self.supportsMultiCam = supportsMultiCam
        self.frameRateRanges = frameRateRanges
    }
}

/// Recording cadence takes priority over resolution or photo-quality flags.
public func cameraPreferredRoundVideoFormat(formats: [CameraRoundVideoFormat], maxWidth: Int32, maxHeight: Int32, requestedFrameRate: Double = 60.0, requiresMultiCam: Bool) -> Int? {
    let candidates = formats.filter {
        $0.isVideoRange420 && $0.width > 0 && $0.height > 0
            && $0.width <= maxWidth && $0.height <= maxHeight
            && (!requiresMultiCam || $0.supportsMultiCam)
    }.compactMap { format -> (CameraRoundVideoFormat, Double)? in
        guard let rate = cameraClosestSupportedFrameRate(requested: requestedFrameRate, ranges: format.frameRateRanges) else { return nil }
        return (format, rate)
    }
    return candidates.min { lhs, rhs in
        let leftDistance = abs(lhs.1 - requestedFrameRate)
        let rightDistance = abs(rhs.1 - requestedFrameRate)
        if leftDistance != rightDistance { return leftDistance < rightDistance }
        let leftArea = Int64(lhs.0.width) * Int64(lhs.0.height)
        let rightArea = Int64(rhs.0.width) * Int64(rhs.0.height)
        if leftArea != rightArea { return leftArea > rightArea }
        let leftMaximum = lhs.0.frameRateRanges.map(\.upperBound).max() ?? 0.0
        let rightMaximum = rhs.0.frameRateRanges.map(\.upperBound).max() ?? 0.0
        if leftMaximum != rightMaximum { return leftMaximum < rightMaximum }
        return lhs.0.index < rhs.0.index
    }?.0.index
}
