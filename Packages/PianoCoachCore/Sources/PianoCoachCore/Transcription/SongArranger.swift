import Foundation

/// A transcription turned into a playable song: a `Score` with beats, measures, hands, key, tempo and
/// loudness, plus what was worked out along the way.
public struct ArrangedSong: Sendable {
    public var score: Score
    /// Quarter-note beats per minute at 100 % speed (also `score.initialTempoBPM`).
    public var tempoBPM: Double
    /// Seconds into the recording where beat 0 falls: recording time = `timeOfBeatZero + beat * 60 / tempoBPM`.
    public var timeOfBeatZero: Double
    public var timeSignature: TimeSignature
    /// Key signature (sharps positive, flats negative), also `score.keyFifths`.
    public var keyFifths: Int
    public var isMinor: Bool
    /// "G major", "E minor", "B♭ major".
    public var keyName: String
    /// Notes in the song, and notes of the transcription left out as noise, fragments or duplicates.
    public var noteCount: Int
    public var removedNoteCount: Int
    /// 0...1: how well the notes fit the beat grid, and how clearly the key won.
    public var tempoConfidence: Double
    public var keyConfidence: Double

    /// Where `beat` falls in the recording, in seconds.
    public func seconds(atBeat beat: Double) -> Double { timeOfBeatZero + beat * 60 / tempoBPM }

    /// The beat at a moment of the recording.
    public func beat(atSeconds seconds: Double) -> Double { (seconds - timeOfBeatZero) * tempoBPM / 60 }

    /// The song as a game chart (marked as worked out by listening, lined up with the recording).
    public var chart: NoteChart? {
        guard var chart = NoteChart.from(score: score) else { return nil }
        chart.source = .listening
        chart.videoTimeOfBeatZero = timeOfBeatZero
        return chart
    }

    /// The song as a Standard MIDI File (see `MIDIFileWriter`).
    public var midiFileData: Data { MIDIFileWriter.data(for: score, isMinor: isMinor) }
}

/// Turns the flat list of notes heard in a recording into a song a child can play and read.
///
/// Steps: clean up transcription noise, split the notes between the hands, find the key, find one steady
/// tempo and the meter, then lay the notes out in beats and measures. Timing is never bent to a grid:
/// beats are a straight rescaling of seconds (see `ArrangedSong.seconds(atBeat:)`), so playing the song
/// at 100 % reproduces the recording's timing. Only notes struck together (a chord) share one onset.
public enum SongArranger {
    public struct Options: Sendable {
        /// Notes shorter than this (seconds) are clicks or transcription noise.
        public var minimumDuration = 0.04
        /// Notes quieter than this fraction of the song's median loudness are dropped as noise.
        public var relativeAmplitudeThreshold = 0.28
        /// A note of the same pitch starting within this many seconds of the previous one's end, much
        /// quieter than it (at most `fragmentAmplitudeRatio`) and not struck together with other notes, is
        /// the rest of that note, split by the transcriber. Otherwise it is a real repeated note.
        public var fragmentGap = 0.03
        public var fragmentAmplitudeRatio = 0.6
        /// A note whose pitch is an overtone of a louder note sounding when it starts (an octave, a twelfth,
        /// two octaves, two octaves and a third, two octaves and a fifth or three octaves above) is a ghost
        /// the transcriber heard in that note's sound when it is quieter than these fractions of it.
        ///
        /// Measured with Basic Pitch on a recorded piano, ghosts reach about 0.55 of their note (octaves
        /// are the strongest), while real notes struck together with a lower note an octave below reach
        /// down to about 0.7 of it, and a twelfth or two octaves below down to about 0.58: these limits
        /// sit between the two.
        public var octaveOvertoneAmplitudeRatio = 0.63
        public var overtoneAmplitudeRatio = 0.5
        /// Limit when the lower note was already sounding: a newly struck note is louder than the fading
        /// one, so a real melody note above a held bass note stays.
        public var sustainedOvertoneAmplitudeRatio = 0.5
        /// Notes starting within this many seconds of each other are struck together.
        public var overtoneOnsetWindow = 0.06
        /// Notes starting within this many seconds (or 1/32 of a beat, if longer) are struck together.
        public var chordWindow = 0.025
        /// Use this tempo instead of estimating one (e.g. when the player corrects a doubled tempo).
        public var tempoBPM: Double?
        /// Use this time signature instead of estimating one.
        public var timeSignature: TimeSignature?
        /// Tempo for songs with too few onsets to measure one.
        public var fallbackTempoBPM = 100.0

        public init() {}
    }

    /// The arranged song, or nil when no usable notes remain after cleanup.
    public static func arrange(_ notes: [TranscribedNote], title: String, options: Options = Options()) -> ArrangedSong? {
        let cleaned = cleanUp(notes, options: options)
        guard let firstOnset = cleaned.first?.start else { return nil }

        var tempoOptions = TempoEstimator.Options()
        tempoOptions.chordWindow = max(options.chordWindow, 0.03)
        var tempo: TempoEstimate
        if let bpm = options.tempoBPM, bpm > 0, let fixed = TempoEstimator.beat(cleaned, bpm: bpm, options: tempoOptions) {
            tempo = fixed
        } else if let estimated = TempoEstimator.estimate(cleaned, options: tempoOptions) {
            tempo = estimated
        } else {
            tempo = TempoEstimate(bpm: options.fallbackTempoBPM, beatTime: firstOnset, confidence: 0)
        }
        let period = tempo.secondsPerBeat
        let window = min(0.045, max(options.chordWindow, period / 32))

        var handOptions = HandSplitter.Options()
        handOptions.chordWindow = window
        let hands = HandSplitter.assignHands(cleaned, options: handOptions)
        let key = KeyEstimator.estimate(cleaned)
        var meter = TempoEstimator.meter(cleaned, tempo: tempo, options: tempoOptions)
        if let fixed = options.timeSignature, fixed.beats > 0, fixed.beatType > 0 { meter.timeSignature = fixed }

        let zero = timeOfBeatZero(firstOnset: firstOnset, tempo: tempo, meter: meter)
        let score = layOut(cleaned, hands: hands, zero: zero, period: period, window: window,
                           signature: meter.timeSignature, title: title, keyFifths: key.fifths)
        return ArrangedSong(score: score, tempoBPM: tempo.bpm, timeOfBeatZero: zero, timeSignature: meter.timeSignature,
                            keyFifths: key.fifths, isMinor: key.isMinor, keyName: key.name,
                            noteCount: score.notes.count, removedNoteCount: notes.count - score.notes.count,
                            tempoConfidence: tempo.confidence, keyConfidence: key.confidence)
    }

    // MARK: - Cleanup

    /// Removes what a transcriber typically gets wrong: overtone ghosts, same-pitch duplicates and
    /// fragments, out-of-range, very short and very quiet notes. Sorted by start, then pitch.
    ///
    /// Ghosts go first so they cannot pass for notes struck together with a fragment, and again after
    /// fragments are joined (a ghost may start during the second half of a split note).
    static func cleanUp(_ notes: [TranscribedNote], options: Options) -> [TranscribedNote] {
        let valid = notes.compactMap { n -> TranscribedNote? in
            guard (Pitch.lowestPianoMIDI...Pitch.highestPianoMIDI).contains(n.midi),
                  n.start.isFinite, n.end.isFinite, n.end > n.start, n.amplitude.isFinite else { return nil }
            var n = n
            n.amplitude = max(0, min(1, n.amplitude))
            return n
        }
        let joined = removeOvertones(joinSamePitch(removeOvertones(valid, options: options), options: options),
                                     options: options)
            .filter { $0.duration >= options.minimumDuration }
        let reference = median(joined.map(\.amplitude))
        return joined.filter { $0.amplitude >= options.relativeAmplitudeThreshold * reference }
            .sorted { ($0.start, $0.midi) < ($1.start, $1.midi) }
    }

    /// Merges duplicates and fragments of one pitch and cuts a note off where the next one of the same
    /// pitch starts (one key cannot sound twice at once).
    static func joinSamePitch(_ notes: [TranscribedNote], options: Options) -> [TranscribedNote] {
        let starts = notes.map { ($0.start, $0.midi) }.sorted { $0 < $1 }
        // True when a note of another pitch starts within the chord window of `note`.
        func struckWithOthers(_ note: TranscribedNote) -> Bool {
            var lo = 0, hi = starts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if starts[mid].0 < note.start - options.chordWindow { lo = mid + 1 } else { hi = mid }
            }
            while lo < starts.count, starts[lo].0 <= note.start + options.chordWindow {
                if starts[lo].1 != note.midi { return true }
                lo += 1
            }
            return false
        }
        var result: [TranscribedNote] = []
        for pitch in Dictionary(grouping: notes, by: \.midi).sorted(by: { $0.key < $1.key }) {
            let sorted = pitch.value.sorted { ($0.start, -$0.end) < ($1.start, -$1.end) }
            var current = sorted[0]
            for next in sorted.dropFirst() {
                let duplicate = next.start - current.start <= options.chordWindow
                let fragment = next.start - current.end < options.fragmentGap
                    && next.amplitude <= options.fragmentAmplitudeRatio * current.amplitude
                    && !struckWithOthers(next)
                if duplicate || fragment {
                    current.end = max(current.end, next.end)
                    if duplicate { current.amplitude = max(current.amplitude, next.amplitude) }
                } else {
                    current.end = min(current.end, next.start)
                    result.append(current)
                    current = next
                }
            }
            result.append(current)
        }
        return result
    }

    /// Harmonics 2, 3, 4, 5, 6 and 8 of a note, in semitones above it.
    static let overtoneIntervals = [12, 19, 24, 28, 31, 36]

    /// Drops overtone ghosts (see `Options.octaveOvertoneAmplitudeRatio`). Works upwards from the lowest
    /// pitch, so a ghost that has been dropped cannot in turn explain away a note above it.
    static func removeOvertones(_ notes: [TranscribedNote], options: Options) -> [TranscribedNote] {
        var kept: [Int: [TranscribedNote]] = [:]
        var result: [TranscribedNote] = []
        for n in notes.sorted(by: { ($0.midi, $0.start) < ($1.midi, $1.start) }) {
            let isGhost = overtoneIntervals.contains { interval in
                (kept[n.midi - interval] ?? []).contains { parent in
                    guard parent.start <= n.start + options.overtoneOnsetWindow, parent.end > n.start else { return false }
                    let together = parent.start >= n.start - options.overtoneOnsetWindow
                    let ratio = !together ? options.sustainedOvertoneAmplitudeRatio
                        : interval == 12 ? options.octaveOvertoneAmplitudeRatio : options.overtoneAmplitudeRatio
                    return n.amplitude < ratio * parent.amplitude
                }
            }
            if !isGhost {
                kept[n.midi, default: []].append(n)
                result.append(n)
            }
        }
        return result
    }

    // MARK: - Beats and measures

    /// Beat 0 is the start of the measure holding the first note. When the first note is played a little
    /// before a beat, the grid is nudged by that difference (at most 40 ms) so the song starts on the beat
    /// rather than just before it.
    static func timeOfBeatZero(firstOnset: Double, tempo: TempoEstimate, meter: MeterEstimate) -> Double {
        let period = tempo.secondsPerBeat
        var grid = tempo.beatTime
        var beat = ((firstOnset - grid) / period).rounded()
        let offset = firstOnset - (grid + beat * period)
        if offset < 0 {
            if -offset <= min(0.04, 0.2 * period) { grid += offset } else { beat -= 1 }
        }
        let beats = meter.timeSignature.quarterBeatsPerMeasure
        let downbeat = ((meter.downbeatTime - tempo.beatTime) / period).rounded()
        let intoMeasure = (beat - downbeat).truncatingRemainder(dividingBy: beats)
        let measureStart = beat - (intoMeasure < 0 ? intoMeasure + beats : intoMeasure)
        return grid + measureStart * period
    }

    static func layOut(_ notes: [TranscribedNote], hands: [Hand], zero: Double, period: Double, window: Double,
                       signature: TimeSignature, title: String, keyFifths: Int) -> Score {
        func beat(_ t: Double) -> Double { max(0, (t - zero) / period) }
        let reference = median(notes.map(\.amplitude))

        var onsets: [(beat: Double, notes: [ScoreNote])] = []
        for group in notes.onsetGroups(window: window) {
            let start = beat(group.map { notes[$0].start }.min()!)
            var byPitch: [Int: ScoreNote] = [:]
            for i in group {
                let n = notes[i]
                let note = ScoreNote(midi: n.midi, beat: start, durationBeats: max(1e-3, beat(n.end) - start),
                                     hand: hands[i], measureIndex: 0,
                                     velocity: velocity(amplitude: n.amplitude, reference: reference))
                if let existing = byPitch[n.midi], existing.durationBeats >= note.durationBeats { continue }
                byPitch[n.midi] = note
            }
            onsets.append((start, byPitch.values.sorted { $0.midi < $1.midi }))
        }

        let measureLength = signature.quarterBeatsPerMeasure
        let lastOnset = onsets.last?.beat ?? 0
        let end = onsets.flatMap(\.notes).map { $0.beat + $0.durationBeats }.max() ?? 0
        var measures: [ScoreMeasure] = []
        var start = 0.0
        repeat {
            measures.append(ScoreMeasure(index: measures.count, sourceIndex: measures.count, number: String(measures.count + 1),
                                         startBeat: start, lengthBeats: measureLength, timeSignature: signature))
            start += measureLength
        } while start <= lastOnset + 1e-9 || start < end - 1.0 / 960

        var events: [ScoreEvent] = []
        var scoreNotes: [ScoreNote] = []
        for (k, onset) in onsets.enumerated() {
            let m = min(measures.count - 1, Int((onset.beat / measureLength + 1e-9).rounded(.down)))
            let duration = k + 1 < onsets.count
                ? onsets[k + 1].beat - onset.beat
                : onset.notes.map(\.durationBeats).max() ?? 0
            events.append(ScoreEvent(index: k, beat: onset.beat, measureIndex: m, sourceMeasureIndex: m,
                                     beatInMeasure: onset.beat - measures[m].startBeat, pitches: onset.notes.map(\.midi),
                                     durationBeats: duration))
            scoreNotes += onset.notes.map { var n = $0; n.measureIndex = m; return n }
        }
        return Score(title: title, measures: measures, events: events, initialTempoBPM: 60 / period,
                     notes: scoreNotes, keyFifths: keyFifths)
    }

    /// Loudness relative to the song's typical note: a typical note plays at 0.7 (MIDI ~89); the scale
    /// is compressed a little and clamped so quiet notes stay audible.
    static func velocity(amplitude: Double, reference: Double) -> Double {
        guard reference > 0 else { return 0.7 }
        return max(0.25, min(1, 0.7 * pow(max(0, amplitude) / reference, 0.8)))
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

extension Array where Element == TranscribedNote {
    /// Indices of notes struck together: each group holds the notes starting within `window` seconds of
    /// its first note. Groups are in time order, each from low to high.
    func onsetGroups(window: Double) -> [[Int]] {
        let order = indices.sorted { (self[$0].start, self[$0].midi, $0) < (self[$1].start, self[$1].midi, $1) }
        var groups: [[Int]] = []
        var i = 0
        while i < order.count {
            let first = self[order[i]].start
            var j = i + 1
            while j < order.count, self[order[j]].start - first <= window { j += 1 }
            groups.append(order[i..<j].sorted { (self[$0].midi, $0) < (self[$1].midi, $1) })
            i = j
        }
        return groups
    }
}
