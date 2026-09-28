import Foundation

/// A known correspondence between a moment in the video and a position in the score.
public struct SyncAnchor: Codable, Hashable, Sendable {
    /// Seconds into the video (at 1x speed).
    public var videoTime: Double
    /// Quarter-note beats from the start of the score (performance order).
    public var beat: Double

    public init(videoTime: Double, beat: Double) {
        self.videoTime = videoTime
        self.beat = beat
    }
}

/// Maps between video time and score beats.
///
/// With fewer than two anchors the map is linear: `videoTime = offset + beat * 60 / bpm`.
/// With anchors it is piecewise linear between anchors and extrapolates beyond the first/last
/// anchor using `bpm`. Anchors are kept sorted and strictly increasing in both beat and time.
public struct SyncMap: Codable, Hashable, Sendable {
    /// Quarter-note tempo of the video at 1x, used for extrapolation.
    public var bpm: Double
    /// Video time (seconds) of beat 0 when no anchors exist.
    public var offset: Double
    public private(set) var anchors: [SyncAnchor]

    public init(bpm: Double, offset: Double = 0, anchors: [SyncAnchor] = []) {
        self.bpm = bpm > 0 ? bpm : 60
        self.offset = offset
        self.anchors = []
        for a in anchors { addAnchor(a) }
    }

    private var secondsPerBeat: Double { 60 / bpm }

    /// Video time for a score beat.
    public func videoTime(forBeat beat: Double) -> Double {
        guard let first = anchors.first else { return offset + beat * secondsPerBeat }
        if anchors.count == 1 || beat <= first.beat {
            return first.videoTime + (beat - first.beat) * secondsPerBeat
        }
        let last = anchors[anchors.count - 1]
        if beat >= last.beat { return last.videoTime + (beat - last.beat) * secondsPerBeat }
        var lo = 0, hi = anchors.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if anchors[mid].beat <= beat { lo = mid } else { hi = mid }
        }
        let a = anchors[lo], b = anchors[hi]
        let f = (beat - a.beat) / (b.beat - a.beat)
        return a.videoTime + f * (b.videoTime - a.videoTime)
    }

    /// Score beat for a video time (inverse of `videoTime(forBeat:)`).
    public func beat(forVideoTime time: Double) -> Double {
        guard let first = anchors.first else { return (time - offset) / secondsPerBeat }
        if anchors.count == 1 || time <= first.videoTime {
            return first.beat + (time - first.videoTime) / secondsPerBeat
        }
        let last = anchors[anchors.count - 1]
        if time >= last.videoTime { return last.beat + (time - last.videoTime) / secondsPerBeat }
        var lo = 0, hi = anchors.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if anchors[mid].videoTime <= time { lo = mid } else { hi = mid }
        }
        let a = anchors[lo], b = anchors[hi]
        let f = (time - a.videoTime) / (b.videoTime - a.videoTime)
        return a.beat + f * (b.beat - a.beat)
    }

    /// Inserts an anchor. An existing anchor within a quarter beat is replaced; anchors that would
    /// break monotonicity (time going backwards as beats go forwards) are removed.
    public mutating func addAnchor(_ anchor: SyncAnchor) {
        anchors.removeAll { abs($0.beat - anchor.beat) < 0.25 }
        anchors.removeAll {
            ($0.beat < anchor.beat && $0.videoTime >= anchor.videoTime) ||
            ($0.beat > anchor.beat && $0.videoTime <= anchor.videoTime)
        }
        let idx = anchors.firstIndex { $0.beat > anchor.beat } ?? anchors.count
        anchors.insert(anchor, at: idx)
    }

    public mutating func removeAllAnchors() {
        anchors.removeAll()
    }
}
