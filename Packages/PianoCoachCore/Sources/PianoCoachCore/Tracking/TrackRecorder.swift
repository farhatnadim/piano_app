import Foundation

/// Builds a `FollowTrack` by listening to the video play once ("Learn this song").
///
/// The app plays the video at normal speed with the sound on; every onset the microphone hears is
/// placed on the video timeline and stored with its pitch features. Later the `ScoreFollower` tracks
/// the child against this reference — no sheet music required.
public final class TrackRecorder {
    /// Delay between the video producing a sound and the analyser timestamping it (speaker, air,
    /// microphone and buffering). Subtracted from each onset's video time.
    public var latency: Double
    /// Onsets closer together than this (video seconds) are merged.
    public var mergeWindow: Double
    /// Onsets weaker than this fraction of the median strength are dropped as echoes/noise.
    public var relativeStrengthFloor: Float

    private var events: [TrackEvent] = []
    public private(set) var coveredRange: ClosedRange<Double>?

    public init(latency: Double = 0.08, mergeWindow: Double = 0.06, relativeStrengthFloor: Float = 0.25) {
        self.latency = latency
        self.mergeWindow = mergeWindow
        self.relativeStrengthFloor = relativeStrengthFloor
    }

    public var eventCount: Int { events.count }

    /// Records the video segment being learned (the range that will replace old data when merging).
    public func noteCovered(videoTime: Double) {
        if let r = coveredRange {
            coveredRange = min(r.lowerBound, videoTime)...max(r.upperBound, videoTime)
        } else {
            coveredRange = videoTime...videoTime
        }
    }

    /// Adds an onset that the analyser heard while the video was at `videoTime` (uncorrected).
    public func add(_ onset: NoteOnset, videoTime: Double) {
        guard !onset.features.isZero else { return }
        let t = max(0, videoTime - latency)
        noteCovered(videoTime: t)
        events.append(TrackEvent(index: events.count, videoTime: t, features: onset.features,
                                 strength: onset.strength))
    }

    /// Discards everything recorded so far.
    public func clear() {
        events.removeAll()
        coveredRange = nil
    }

    /// Cleans up the recording and returns it as a track.
    public func finish() -> FollowTrack {
        var sorted = events.sorted { $0.videoTime < $1.videoTime }
        guard !sorted.isEmpty else { return FollowTrack(origin: .learnedFromVideo, events: []) }

        let strengths = sorted.map(\.strength).sorted()
        let median = strengths[strengths.count / 2]
        let floor = median * relativeStrengthFloor
        sorted.removeAll { $0.strength < floor }

        var merged: [TrackEvent] = []
        for e in sorted {
            if let last = merged.last, e.videoTime - last.videoTime < mergeWindow {
                // Keep the stronger attack's features.
                if e.strength > last.strength {
                    merged[merged.count - 1].features = e.features
                    merged[merged.count - 1].strength = e.strength
                }
            } else {
                merged.append(e)
            }
        }
        let maxStrength = merged.map(\.strength).max() ?? 1
        let normalised = merged.map { e -> TrackEvent in
            var e = e
            e.strength = maxStrength > 0 ? min(1, e.strength / maxStrength) : 1
            return e
        }
        return FollowTrack(origin: .learnedFromVideo, events: normalised)
    }

    /// Replaces the part of `base` inside `range` with `new` (used when a section is learned again).
    public static func merge(base: FollowTrack?, with new: FollowTrack, replacing range: ClosedRange<Double>) -> FollowTrack {
        guard let base, !base.isEmpty else { return new }
        let pad = 0.05
        let kept = base.events.filter { $0.videoTime < range.lowerBound - pad || $0.videoTime > range.upperBound + pad }
        return FollowTrack(origin: .learnedFromVideo, events: kept + new.events)
    }
}
