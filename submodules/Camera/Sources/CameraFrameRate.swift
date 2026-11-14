import Foundation

/// Chooses from all supported ranges; the first range may only support 30 fps
/// even when a later range supports the requested 60 fps.
public func cameraClosestSupportedFrameRate(requested: Double, ranges: [ClosedRange<Double>]) -> Double? {
    guard requested.isFinite, requested > 0.0 else { return nil }
    let candidates = ranges.compactMap { range -> Double? in
        guard range.lowerBound.isFinite, range.upperBound.isFinite, range.lowerBound > 0.0 else { return nil }
        return min(range.upperBound, max(range.lowerBound, requested))
    }
    return candidates.min(by: { abs($0 - requested) < abs($1 - requested) })
}
