import Foundation

/// A time signature such as 3/4 or 6/8.
public struct TimeSignature: Codable, Hashable, Sendable {
    public var beats: Int
    public var beatType: Int

    public init(beats: Int, beatType: Int) {
        self.beats = beats
        self.beatType = beatType
    }

    public static let common = TimeSignature(beats: 4, beatType: 4)

    /// Length of one full measure in quarter-note beats (6/8 -> 3.0, 3/4 -> 3.0, 4/4 -> 4.0).
    public var quarterBeatsPerMeasure: Double {
        guard beatType > 0 else { return 4 }
        return Double(beats) * 4 / Double(beatType)
    }
}

/// One measure of a score, in *performance order* (repeats unrolled).
///
/// All beat values in the core package are measured in quarter notes.
public struct ScoreMeasure: Codable, Hashable, Sendable {
    /// Performance-order index, 0-based. Measures played twice because of a repeat appear twice.
    public var index: Int
    /// 0-based ordinal of the `<measure>` element in the source file (what the sheet display uses).
    public var sourceIndex: Int
    /// Printed measure number label from the file (e.g. "12", "0" for a pickup, "12a").
    public var number: String
    /// Start of the measure in quarter-note beats from the beginning of the performance.
    public var startBeat: Double
    /// Actual length in quarter-note beats (pickup measures can be shorter than the time signature).
    public var lengthBeats: Double
    public var timeSignature: TimeSignature

    public init(index: Int, sourceIndex: Int, number: String, startBeat: Double, lengthBeats: Double, timeSignature: TimeSignature) {
        self.index = index
        self.sourceIndex = sourceIndex
        self.number = number
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
        self.timeSignature = timeSignature
    }

    public var endBeat: Double { startBeat + lengthBeats }
}

/// A group of notes that start at the same moment (a single note or a chord),
/// merged across all parts, staves and voices.
public struct ScoreEvent: Codable, Hashable, Sendable {
    /// Position in `Score.events`.
    public var index: Int
    /// Onset in quarter-note beats from the start of the performance (repeats unrolled).
    public var beat: Double
    /// Performance-order measure index (into `Score.measures`).
    public var measureIndex: Int
    /// Source measure ordinal (for positioning the sheet-music cursor).
    public var sourceMeasureIndex: Int
    /// Onset relative to the start of its measure, in quarter-note beats.
    public var beatInMeasure: Double
    /// Sorted, de-duplicated MIDI numbers newly struck at this onset. Tied continuations are excluded.
    public var pitches: [Int]
    /// Beats until the next event (for the last event: the longest note duration).
    public var durationBeats: Double

    public init(index: Int, beat: Double, measureIndex: Int, sourceMeasureIndex: Int, beatInMeasure: Double, pitches: [Int], durationBeats: Double) {
        self.index = index
        self.beat = beat
        self.measureIndex = measureIndex
        self.sourceMeasureIndex = sourceMeasureIndex
        self.beatInMeasure = beatInMeasure
        self.pitches = pitches
        self.durationBeats = durationBeats
    }
}

/// A parsed piece of music reduced to what the coach needs: measures and a timeline of note onsets.
public struct Score: Codable, Hashable, Sendable {
    public var title: String?
    public var composer: String?
    /// Measures in performance order.
    public var measures: [ScoreMeasure]
    /// Onset events sorted by `beat` (strictly increasing).
    public var events: [ScoreEvent]
    /// Initial tempo in quarter notes per minute, if the file specifies one.
    public var initialTempoBPM: Double?

    public init(title: String? = nil, composer: String? = nil, measures: [ScoreMeasure], events: [ScoreEvent], initialTempoBPM: Double? = nil) {
        self.title = title
        self.composer = composer
        self.measures = measures
        self.events = events
        self.initialTempoBPM = initialTempoBPM
    }

    /// Total length in quarter-note beats.
    public var totalBeats: Double {
        if let last = measures.last { return last.endBeat }
        if let last = events.last { return last.beat + last.durationBeats }
        return 0
    }

    /// Performance-order index of the measure containing `beat` (clamped to the score).
    public func measureIndex(atBeat beat: Double) -> Int? {
        guard !measures.isEmpty else { return nil }
        var lo = 0, hi = measures.count - 1
        if beat <= measures[0].startBeat { return 0 }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if measures[mid].startBeat <= beat { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Index of the last event whose onset is at or before `beat`, or nil if `beat` precedes all events.
    public func eventIndex(atOrBefore beat: Double) -> Int? {
        guard let first = events.first, beat >= first.beat - 1e-9 else { return nil }
        var lo = 0, hi = events.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if events[mid].beat <= beat + 1e-9 { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// First performance-order measure whose printed number equals `number`;
    /// falls back to treating `number` as a 1-based count of full measures.
    public func measure(numbered number: Int) -> ScoreMeasure? {
        let label = String(number)
        if let m = measures.first(where: { $0.number == label }) { return m }
        // Printed numbers missing or non-numeric: count measures, skipping a leading pickup.
        let hasPickup = measures.first.map { $0.lengthBeats + 1e-6 < $0.timeSignature.quarterBeatsPerMeasure } ?? false
        let idx = number - 1 + (hasPickup ? 1 : 0)
        return measures.indices.contains(idx) ? measures[idx] : nil
    }
}
