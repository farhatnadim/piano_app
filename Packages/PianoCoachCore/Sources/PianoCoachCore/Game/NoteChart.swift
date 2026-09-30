import Foundation

/// Where a chart's notes came from.
public enum ChartSource: String, Codable, Sendable {
    /// Exact notes from imported sheet music (MusicXML or MIDI).
    case score
    /// Notes worked out by listening to the video (approximate).
    case listening
}

/// One note the player has to play.
public struct ChartNote: Codable, Hashable, Identifiable, Sendable {
    /// Position in `NoteChart.notes`.
    public var id: Int
    public var midi: Int
    /// When the note should be played, in beats from the start of the chart.
    public var time: Double
    /// How long it is held, in beats (drawn as the length of the falling bar).
    public var duration: Double
    public var hand: Hand
    /// How hard to play it back, 0...1 (MIDI velocity / 127); nil when unknown (use a default loudness).
    public var velocity: Double?

    public init(id: Int, midi: Int, time: Double, duration: Double, hand: Hand, velocity: Double? = nil) {
        self.id = id
        self.midi = midi
        self.time = time
        self.duration = duration
        self.hand = hand
        self.velocity = velocity
    }

    public var end: Double { time + duration }
}

/// The notes of a song as a game plays them: pitches on a timeline measured in beats.
///
/// At 100 % speed one beat lasts `60 / beatsPerMinute` seconds. Charts made by `fromListening` use
/// 60 BPM, so their beats are simply seconds of the original video.
public struct NoteChart: Codable, Hashable, Sendable {
    public var title: String
    /// Sorted by time, then pitch; `id` equals the index.
    public private(set) var notes: [ChartNote]
    /// Tempo at 100 % speed.
    public var beatsPerMinute: Double
    /// Beats where measures start (for drawing bar lines); empty when unknown.
    public var barLines: [Double]
    public var source: ChartSource
    /// Key signature (sharps positive, flats negative), used to spell note names.
    public var keyFifths: Int
    /// For charts made by listening: the video time of beat 0, to line the chart up with the video.
    public var videoTimeOfBeatZero: Double?

    public init(title: String, notes: [ChartNote], beatsPerMinute: Double, barLines: [Double] = [],
                source: ChartSource, keyFifths: Int = 0, videoTimeOfBeatZero: Double? = nil) {
        self.title = title
        self.beatsPerMinute = beatsPerMinute > 0 && beatsPerMinute.isFinite ? beatsPerMinute : 60
        self.barLines = barLines
        self.source = source
        self.keyFifths = keyFifths
        self.videoTimeOfBeatZero = videoTimeOfBeatZero
        let sorted = notes.sorted { ($0.time, $0.midi) < ($1.time, $1.midi) }
        self.notes = sorted.enumerated().map { i, n in
            var n = n
            n.id = i
            return n
        }
    }

    public var isEmpty: Bool { notes.isEmpty }
    /// Beat at which the last note ends.
    public var endBeat: Double { notes.map(\.end).max() ?? 0 }
    public var lowestMIDI: Int { notes.map(\.midi).min() ?? 60 }
    public var highestMIDI: Int { notes.map(\.midi).max() ?? 72 }

    /// Seconds per beat at a given speed (1 = the song's tempo).
    public func secondsPerBeat(atSpeed speed: Double) -> Double {
        60 / (beatsPerMinute * max(0.05, speed))
    }

    /// Notes grouped into chords (notes that start together), in time order.
    public var chords: [[ChartNote]] {
        var result: [[ChartNote]] = []
        for note in notes {
            if let last = result.last?.first, abs(last.time - note.time) < 1e-3 {
                result[result.count - 1].append(note)
            } else {
                result.append([note])
            }
        }
        return result
    }

    // MARK: - Building charts

    /// A chart from sheet music. Nil if the score has no notes. Scores without per-note data fall back to
    /// their onset events (hands split at middle C).
    public static func from(score: Score, title: String? = nil) -> NoteChart? {
        let notes: [ChartNote]
        if !score.notes.isEmpty {
            notes = score.notes.map {
                ChartNote(id: 0, midi: $0.midi, time: $0.beat, duration: max(0.1, $0.durationBeats), hand: $0.hand,
                          velocity: $0.velocity)
            }
        } else {
            notes = score.events.flatMap { e in
                e.pitches.map { ChartNote(id: 0, midi: $0, time: e.beat, duration: max(0.1, e.durationBeats),
                                          hand: $0 >= 60 ? .right : .left) }
            }
        }
        guard !notes.isEmpty else { return nil }
        return NoteChart(title: title ?? score.title ?? "Song", notes: notes,
                         beatsPerMinute: score.initialTempoBPM ?? 90,
                         barLines: score.measures.map(\.startBeat), source: .score, keyFifths: score.keyFifths)
    }

    /// A chart worked out from what the coach heard while the video played (see `TrackRecorder`).
    /// Times are video seconds shifted so the first note comes after `leadIn` seconds.
    public static func fromListening(track: FollowTrack, title: String, leadIn: Double = 1) -> NoteChart? {
        let events = track.events.filter { !$0.features.isZero }
        guard let first = events.first else { return nil }
        let zero = first.videoTime - leadIn
        var notes: [ChartNote] = []
        for (i, event) in events.enumerated() {
            let pitches = event.pitches.isEmpty ? NoteTranscriber.pitches(in: event.features) : event.pitches
            let next = i + 1 < events.count ? events[i + 1].videoTime : event.videoTime + 1
            let length = max(0.15, min(1.2, next - event.videoTime))
            for midi in pitches {
                notes.append(ChartNote(id: 0, midi: midi, time: event.videoTime - zero, duration: length,
                                       hand: midi >= 60 ? .right : .left))
            }
        }
        guard !notes.isEmpty else { return nil }
        return NoteChart(title: title, notes: notes, beatsPerMinute: 60, source: .listening,
                         videoTimeOfBeatZero: zero)
    }
}
