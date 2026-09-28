import Foundation

/// Answers "where was the video at clock time t?" from periodic player reports.
///
/// The player reports its position ~10 times per second; onsets arrive ~60-100 ms after they
/// happened. Keeping a short history lets us place an onset precisely on the video timeline.
public struct VideoClock: Sendable {
    private struct Sample: Sendable {
        var clock: Double
        var videoTime: Double
        var rate: Double
        var isPlaying: Bool
    }
    private var samples: [Sample] = []
    public var historyLength: Int

    public init(historyLength: Int = 64) {
        self.historyLength = historyLength
    }

    public mutating func reset() {
        samples.removeAll()
    }

    /// Records the player's state as observed at `clockTime`.
    public mutating func update(videoTime: Double, rate: Double, isPlaying: Bool, at clockTime: Double) {
        if let last = samples.last, clockTime < last.clock { samples.removeAll() }
        samples.append(Sample(clock: clockTime, videoTime: videoTime, rate: rate, isPlaying: isPlaying))
        if samples.count > historyLength { samples.removeFirst(samples.count - historyLength) }
    }

    /// Video position at `clockTime`, extrapolated from the closest earlier report (nil if none).
    public func videoTime(at clockTime: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        // Latest sample at or before clockTime; if clockTime predates history use the oldest.
        var chosen = samples[0]
        for s in samples.reversed() where s.clock <= clockTime {
            chosen = s
            break
        }
        guard chosen.isPlaying else { return chosen.videoTime }
        return chosen.videoTime + (clockTime - chosen.clock) * chosen.rate
    }

    /// Whether the video was playing at `clockTime` (false if unknown).
    public func isPlaying(at clockTime: Double) -> Bool {
        samples.last { $0.clock <= clockTime }?.isPlaying ?? false
    }
}
