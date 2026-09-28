import Foundation

/// One expected "something is played here" moment in a reference track.
public struct TrackEvent: Codable, Hashable, Sendable {
    /// Position in `FollowTrack.events`.
    public var index: Int
    /// Seconds into the video (at 1x) where this event sounds.
    public var videoTime: Double
    /// Score beat, when the track came from (or was aligned to) a score.
    public var beat: Double?
    /// Source measure ordinal for the sheet-music cursor, when known.
    public var sourceMeasureIndex: Int?
    /// Beat within that measure, when known.
    public var beatInMeasure: Double?
    /// MIDI pitches when known (score tracks). Empty for tracks learned by listening to the video.
    public var pitches: [Int]
    /// Expected pitch content.
    public var features: FeatureVector
    /// Relative loudness 0...1 (learned tracks); 1 for score tracks.
    public var strength: Float

    public init(index: Int, videoTime: Double, beat: Double? = nil, sourceMeasureIndex: Int? = nil,
                beatInMeasure: Double? = nil, pitches: [Int] = [], features: FeatureVector, strength: Float = 1) {
        self.index = index
        self.videoTime = videoTime
        self.beat = beat
        self.sourceMeasureIndex = sourceMeasureIndex
        self.beatInMeasure = beatInMeasure
        self.pitches = pitches
        self.features = features
        self.strength = strength
    }
}

/// Where a follow track came from.
public enum TrackOrigin: String, Codable, Sendable {
    /// Built by listening (through the microphone) to the video playing once.
    case learnedFromVideo
    /// Built from an imported score (MusicXML/MIDI) plus a `SyncMap`.
    case score
}

/// The reference sequence the `ScoreFollower` tracks the child against, expressed in video time.
///
/// Because every event carries a `videoTime`, the follower's position converts directly into
/// "where the video should be", whatever the track's origin.
public struct FollowTrack: Codable, Hashable, Sendable {
    public var origin: TrackOrigin
    /// Events sorted by `videoTime` (non-decreasing), `index` equal to their position.
    public var events: [TrackEvent]

    public init(origin: TrackOrigin, events: [TrackEvent]) {
        self.origin = origin
        let sorted = events.sorted { $0.videoTime < $1.videoTime }
        self.events = sorted.enumerated().map { i, e in
            var e = e
            e.index = i
            return e
        }
    }

    public var isEmpty: Bool { events.isEmpty }
    public var startTime: Double { events.first?.videoTime ?? 0 }
    public var endTime: Double { events.last?.videoTime ?? 0 }

    /// Builds a track from a score: each score event becomes a track event at the video time given by `syncMap`.
    public static func fromScore(_ score: Score, syncMap: SyncMap) -> FollowTrack {
        let events = score.events.map { e in
            TrackEvent(index: e.index,
                       videoTime: syncMap.videoTime(forBeat: e.beat),
                       beat: e.beat,
                       sourceMeasureIndex: e.sourceMeasureIndex,
                       beatInMeasure: e.beatInMeasure,
                       pitches: e.pitches,
                       features: .template(forPitches: e.pitches),
                       strength: 1)
        }
        return FollowTrack(origin: .score, events: events)
    }

    /// Index of the last event at or before `time`, or nil if `time` precedes the first event.
    public func eventIndex(atOrBeforeVideoTime time: Double) -> Int? {
        guard let first = events.first, time >= first.videoTime - 1e-9 else { return nil }
        var lo = 0, hi = events.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if events[mid].videoTime <= time + 1e-9 { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Index of the first event at or after `time`, or nil if `time` is past the last event.
    public func eventIndex(atOrAfterVideoTime time: Double) -> Int? {
        guard let last = events.last, time <= last.videoTime + 1e-9 else { return nil }
        var lo = 0, hi = events.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if events[mid].videoTime >= time - 1e-9 { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}
