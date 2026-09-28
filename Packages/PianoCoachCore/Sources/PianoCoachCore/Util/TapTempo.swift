import Foundation

/// Tap-along tempo detection ("tap the beat").
///
/// The tempo is 60 / median of the recent inter-tap intervals, so one early or late tap barely moves it.
/// A pause longer than `maxInterval` starts a new measurement.
public struct TapTempo: Sendable {
    /// Longest gap (seconds) between taps that still belongs to the same measurement.
    public let maxInterval: Double
    /// Number of most recent taps kept (at least 2).
    public let maxTaps: Int

    private var taps: [Double] = []

    public init(maxInterval: Double = 2.0, maxTaps: Int = 8) {
        self.maxInterval = maxInterval > 0 ? maxInterval : 2.0
        self.maxTaps = max(2, maxTaps)
    }

    /// Records a tap at `time` (seconds, any monotonic clock) and returns the current tempo, if known.
    ///
    /// A tap at the same time as the previous one is ignored; a tap earlier than the previous one or more
    /// than `maxInterval` after it starts a new measurement.
    @discardableResult
    public mutating func tap(at time: Double) -> Double? {
        guard time.isFinite else { return bpm }
        if let last = taps.last {
            if time == last { return bpm }
            if time < last || time - last > maxInterval { taps.removeAll() }
        }
        taps.append(time)
        if taps.count > maxTaps { taps.removeFirst(taps.count - maxTaps) }
        return bpm
    }

    /// Forgets all taps.
    public mutating func reset() {
        taps.removeAll()
    }

    /// Number of taps in the current measurement.
    public var tapCount: Int { taps.count }

    /// Beats per minute from the median recent interval; nil until there are at least two taps.
    public var bpm: Double? {
        guard taps.count >= 2 else { return nil }
        var intervals: [Double] = []
        intervals.reserveCapacity(taps.count - 1)
        for i in 1..<taps.count { intervals.append(taps[i] - taps[i - 1]) }
        intervals.sort()
        let mid = intervals.count / 2
        let median = intervals.count % 2 == 1 ? intervals[mid] : (intervals[mid - 1] + intervals[mid]) / 2
        guard median > 0 else { return nil }
        return 60 / median
    }
}
