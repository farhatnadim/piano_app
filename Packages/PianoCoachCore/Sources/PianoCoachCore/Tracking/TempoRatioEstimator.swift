import Foundation

/// Estimates how fast the child moves through the video's timeline ("0.6" = at 60 % of the video's
/// speed) from recent (clock time, video time) pairs of matched notes.
///
/// Uses a local Theil-Sen estimator: the median of the slopes between neighbouring matched notes
/// (and notes two apart). A single hesitation only disturbs the few slopes that span it, so the
/// estimate reflects the child's playing tempo rather than their pauses. The result is then smoothed.
public struct TempoRatioEstimator: Sendable {
    public var maxPoints: Int
    public var maxAge: Double
    public var minRatio: Double
    public var maxRatio: Double
    /// Weight of the newest estimate in the exponential smoothing (0...1).
    public var smoothing: Double

    private var points: [(clock: Double, video: Double)] = []
    public private(set) var ratio: Double?

    public init(maxPoints: Int = 10, maxAge: Double = 12, minRatio: Double = 0.1, maxRatio: Double = 2.5, smoothing: Double = 0.35) {
        self.maxPoints = maxPoints
        self.maxAge = maxAge
        self.minRatio = minRatio
        self.maxRatio = maxRatio
        self.smoothing = smoothing
    }

    /// Forgets the history (after a jump or restart) but keeps the last smoothed ratio as a prior.
    public mutating func restartSegment() {
        points.removeAll()
    }

    /// Forgets everything.
    public mutating func reset() {
        points.removeAll()
        ratio = nil
    }

    /// Adds a matched note and returns the updated ratio (nil until enough evidence).
    @discardableResult
    public mutating func add(clockTime: Double, videoTime: Double) -> Double? {
        if let last = points.last, clockTime <= last.clock { return ratio }
        points.append((clockTime, videoTime))
        points.removeAll { clockTime - $0.clock > maxAge }
        if points.count > maxPoints { points.removeFirst(points.count - maxPoints) }
        guard points.count >= 3, let first = points.first, clockTime - first.clock >= 0.8 else { return ratio }

        var slopes: [Double] = []
        slopes.reserveCapacity(points.count * (points.count - 1) / 2)
        for i in 0..<points.count {
            for j in (i + 1)..<min(points.count, i + 3) {
                let dt = points[j].clock - points[i].clock
                guard dt > 0.05 else { continue }
                slopes.append((points[j].video - points[i].video) / dt)
            }
        }
        guard !slopes.isEmpty else { return ratio }
        slopes.sort()
        let median = slopes[slopes.count / 2]
        let clamped = max(minRatio, min(maxRatio, median))
        if let previous = ratio {
            ratio = previous + smoothing * (clamped - previous)
        } else {
            ratio = clamped
        }
        return ratio
    }
}
