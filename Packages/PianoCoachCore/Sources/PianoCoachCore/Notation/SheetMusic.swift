import Foundation

/// A written note length: whole, half, quarter, eighth or sixteenth, maybe dotted.
public struct NoteValue: Hashable, Sendable {
    /// 1 whole, 2 half, 4 quarter, 8 eighth, 16 sixteenth.
    public var base: Int
    public var dotted: Bool

    public init(base: Int, dotted: Bool = false) {
        self.base = base
        self.dotted = dotted
    }

    public static let whole = NoteValue(base: 1)
    public static let half = NoteValue(base: 2)
    public static let quarter = NoteValue(base: 4)
    public static let eighth = NoteValue(base: 8)
    public static let sixteenth = NoteValue(base: 16)

    /// Length in quarter-note beats.
    public var beats: Double { 4 / Double(base) * (dotted ? 1.5 : 1) }
    /// Flags (or beams): one for an eighth, two for a sixteenth.
    public var flags: Int {
        switch base {
        case 8: return 1
        case 16: return 2
        case 32: return 3
        default: return 0
        }
    }
    public var hasStem: Bool { base >= 2 }
    /// A filled (black) notehead: quarters and shorter.
    public var isFilled: Bool { base >= 4 }

    /// The values sheet music is written in here, longest first.
    public static let written: [NoteValue] = [
        .whole, NoteValue(base: 2, dotted: true), .half, NoteValue(base: 4, dotted: true), .quarter,
        NoteValue(base: 8, dotted: true), .eighth, .sixteenth,
    ]

    /// The written value closest to `beats`.
    public static func nearest(toBeats beats: Double) -> NoteValue {
        written.min { abs($0.beats - beats) < abs($1.beats - beats) } ?? .quarter
    }
}

/// A song written as sheet music on a grand staff: note values, rests, ties across bar lines, accidentals,
/// stem directions and beams, worked out from a game chart.
///
/// Timing comes from the chart, whose notes may sit a little off the beat (songs learned from a recording):
/// each note keeps its exact time for where it is drawn, so it reaches the playhead exactly when it's
/// due, while its written value comes from its time and length rounded to a sixteenth-note grid. Notes a
/// little shorter than the time to the next note are written as lasting until it (a transcription's
/// notes often end a moment early), and each staff is written as one voice: chords, with every note held
/// until the next chord at most.
public struct SheetMusic: Sendable {
    public enum Clef: Int, Sendable {
        case treble, bass
    }

    public enum Accidental: Int, Sendable {
        case flat = -1, natural = 0, sharp = 1
    }

    public struct Measure: Equatable, Sendable {
        public var startBeat: Double
        public var lengthBeats: Double
        public var timeSignature: TimeSignature
        /// The first measure, or a change of time signature.
        public var showsTimeSignature: Bool
        public var endBeat: Double { startBeat + lengthBeats }
    }

    public struct Head: Equatable, Sendable {
        public var midi: Int
        public var spelled: SpelledNote
        public var staffStep: Int { spelled.staffStep }
        /// The sign written before the note, if it needs one (the key signature and earlier notes in the
        /// measure decide).
        public var accidental: Accidental?
        /// The chart note this head writes (its tied continuations too).
        public var chartNoteID: Int?
    }

    public struct Event: Equatable, Sendable {
        public var clef: Clef
        /// Where it is drawn, in beats: the chart time of the notes it starts (so it lines up with the
        /// game), or its place on the grid for rests and tied continuations.
        public var beat: Double
        /// Its place on the sixteenth-note grid.
        public var gridBeat: Double
        public var value: NoteValue
        /// The notes, lowest first; empty for a rest.
        public var heads: [Head]
        /// A whole-measure rest (drawn in the middle of the measure whatever its length).
        public var isMeasureRest: Bool
        public var stemUp: Bool
        /// Index into `beams` when the note is beamed with its neighbours.
        public var beam: Int?
        /// The event its notes are tied to (the rest of the same notes), if any.
        public var tiedTo: Int?
        /// Whether its notes continue notes tied from before (no accidentals are written on them).
        public var isTieContinuation: Bool

        public var isRest: Bool { heads.isEmpty }
        public var measureIndex: Int = 0
    }

    public var measures: [Measure]
    /// Sorted by grid position, treble before bass at the same moment.
    public var events: [Event]
    /// Groups of beamed events (indices into `events`), each in time order.
    public var beams: [[Int]]
    public var keyFifths: Int

    /// Sixteenth notes.
    public static let grid = 0.25

    /// Treble-staff middle line (B4) and bass-staff middle line (D3), as staff steps.
    public static let middleStep: [Clef: Int] = [.treble: 34, .bass: 22]

    // MARK: - Building

    public init(chart: NoteChart) {
        keyFifths = chart.keyFifths
        let notes = chart.notes
        let songEnd = (notes.map(\.end).max() ?? 0)
        measures = Self.measures(barLines: chart.barLines, signatures: chart.timeSignatures, until: songEnd)
        events = []
        beams = []

        // Per staff: chords on the grid.
        for clef in [Clef.treble, .bass] {
            let staffNotes = notes.filter { Self.clef(for: $0, keyFifths: chart.keyFifths) == clef }
            let chords = Self.chords(of: staffNotes)
            appendEvents(for: chords, clef: clef, keyFifths: chart.keyFifths)
        }
        events.sort { ($0.gridBeat, $0.clef.rawValue, $0.beat) < ($1.gridBeat, $1.clef.rawValue, $1.beat) }
        linkTies()
        writeAccidentals()
        findBeams()
        chooseStems()
    }

    /// Right hand on the treble staff and left hand on the bass staff, unless that would need more than
    /// three ledger lines (then the pitch decides).
    public static func clef(for note: ChartNote, keyFifths: Int) -> Clef {
        let step = NoteSpelling.spell(note.midi, keyFifths: keyFifths).staffStep
        switch note.hand {
        case .right: return step >= 24 || note.midi >= 60 ? .treble : .bass
        case .left: return step > 32 && note.midi >= 60 ? .treble : .bass
        }
    }

    /// Measures from bar lines (with their time signatures when known), extended to cover `end`.
    static func measures(barLines: [Double], signatures: [TimeSignature]?, until end: Double) -> [Measure] {
        var starts = barLines.filter { $0.isFinite }.sorted()
        if starts.isEmpty || starts[0] > 1e-9 { starts.insert(0, at: 0) }
        var result: [Measure] = []
        for (i, start) in starts.enumerated() {
            let signature: TimeSignature
            if let signatures, i < signatures.count {
                signature = signatures[i]
            } else if i + 1 < starts.count {
                signature = inferredSignature(length: starts[i + 1] - start)
            } else {
                signature = result.last?.timeSignature ?? .common
            }
            let length = i + 1 < starts.count ? starts[i + 1] - start : signature.quarterBeatsPerMeasure
            guard length > 1e-6 else { continue }
            result.append(Measure(startBeat: start, lengthBeats: length, timeSignature: signature,
                                  showsTimeSignature: result.last.map { $0.timeSignature != signature } ?? true))
        }
        // Enough measures to hold every note.
        while let last = result.last, last.endBeat < end - 1e-6 {
            result.append(Measure(startBeat: last.endBeat, lengthBeats: last.timeSignature.quarterBeatsPerMeasure,
                                  timeSignature: last.timeSignature, showsTimeSignature: false))
        }
        return result
    }

    static func inferredSignature(length: Double) -> TimeSignature {
        let quarters = (length * 1e6).rounded() / 1e6
        if abs(quarters - quarters.rounded()) < 1e-6 { return TimeSignature(beats: max(1, Int(quarters.rounded())), beatType: 4) }
        return TimeSignature(beats: max(1, Int((quarters * 2).rounded())), beatType: 8)
    }

    // MARK: Chords

    struct Chord {
        var time: Double
        var start: Double
        var end: Double
        var notes: [ChartNote]
    }

    /// `beat` rounded to the sixteenth-note grid.
    public static func snap(_ beat: Double) -> Double { (beat / grid).rounded() * grid }

    static func isOnGrid(_ beat: Double) -> Bool { abs(beat - snap(beat)) < 1e-6 }

    /// Notes starting on the same grid point become one chord, held until the next chord at most, and
    /// until it when they end just before it.
    static func chords(of notes: [ChartNote]) -> [Chord] {
        var byStart: [Double: [ChartNote]] = [:]
        for note in notes { byStart[snap(note.time), default: []].append(note) }
        let starts = byStart.keys.sorted()
        var chords: [Chord] = []
        for (i, start) in starts.enumerated() {
            let group = byStart[start]!.sorted { $0.midi < $1.midi }
            var unique: [ChartNote] = []
            for note in group where unique.last?.midi != note.midi { unique.append(note) }
            var end = max(start + grid, unique.map { snap($0.end) }.max() ?? start + grid)
            if i + 1 < starts.count {
                let next = starts[i + 1]
                // Notes that aren't already exact (written, or set by hand) and end a moment early: legato.
                let exact = unique.allSatisfy { isOnGrid($0.time) && isOnGrid($0.duration) }
                let gap = next - end
                if !exact, gap > 1e-6, gap <= max(grid, 0.3 * (next - start)) + 1e-6 { end = next }
                end = min(end, next)
            }
            chords.append(Chord(time: unique.map(\.time).min() ?? start, start: start, end: max(end, start + grid),
                                notes: unique))
        }
        return chords
    }

    // MARK: Events

    private mutating func appendEvents(for chords: [Chord], clef: Clef, keyFifths: Int) {
        var chordIndex = 0
        for (m, measure) in measures.enumerated() {
            var cursor = measure.startBeat
            var measureEvents: [Event] = []
            // Chords (or parts of chords) sounding in this measure, with rests between.
            while chordIndex < chords.count, chords[chordIndex].end <= measure.startBeat + 1e-9 { chordIndex += 1 }
            var k = chordIndex
            while k < chords.count, chords[k].start < measure.endBeat - 1e-9 {
                let chord = chords[k]
                let from = max(chord.start, measure.startBeat)
                let to = min(chord.end, measure.endBeat)
                if from > cursor + 1e-9 {
                    measureEvents += rests(from: cursor, to: from, measure: m, clef: clef)
                }
                if to > from + 1e-9 {
                    let continues = chord.start < measure.startBeat - 1e-9
                    let heads = chord.notes.map {
                        Head(midi: $0.midi, spelled: NoteSpelling.spell($0.midi, keyFifths: keyFifths), accidental: nil,
                             chartNoteID: $0.id)
                    }
                    let values = Self.values(from: from - measure.startBeat, length: to - from, in: measure)
                    var at = from
                    for (j, value) in values.enumerated() {
                        let isFirst = j == 0 && !continues
                        measureEvents.append(Event(clef: clef, beat: isFirst ? chord.time : at, gridBeat: at, value: value,
                                                   heads: heads,
                                                   isMeasureRest: false, stemUp: true, beam: nil, tiedTo: nil,
                                                   isTieContinuation: !isFirst, measureIndex: m))
                        at += value.beats
                    }
                    cursor = max(cursor, to)
                }
                if chord.end > measure.endBeat + 1e-9 { break }   // continues into the next measure
                k += 1
            }
            chordIndex = k
            if measureEvents.isEmpty {
                measureEvents = [Event(clef: clef, beat: measure.startBeat, gridBeat: measure.startBeat, value: .whole,
                                       heads: [], isMeasureRest: true, stemUp: true, beam: nil, tiedTo: nil,
                                       isTieContinuation: false, measureIndex: m)]
            } else if measure.endBeat > cursor + 1e-9 {
                measureEvents += rests(from: cursor, to: measure.endBeat, measure: m, clef: clef)
            }
            events += measureEvents
        }
    }

    private func rests(from: Double, to: Double, measure m: Int, clef: Clef) -> [Event] {
        let measure = measures[m]
        var at = from
        return Self.values(from: from - measure.startBeat, length: to - from, in: measure).map { value in
            defer { at += value.beats }
            return Event(clef: clef, beat: at, gridBeat: at, value: value, heads: [], isMeasureRest: false,
                         stemUp: true, beam: nil, tiedTo: nil, isTieContinuation: false, measureIndex: m)
        }
    }

    /// Splits a length starting `position` beats into a measure into written values: the longest value
    /// that fits and starts where such a value may start (a half note on a beat, an eighth on a
    /// sixteenth…), again and again.
    public static func values(from position: Double, length: Double, in measure: Measure) -> [NoteValue] {
        var result: [NoteValue] = []
        var p = position
        var remaining = length
        func multiple(_ x: Double, of unit: Double) -> Bool { abs(x / unit - (x / unit).rounded()) < 1e-6 }
        while remaining > 1e-6 {
            let fits = NoteValue.written.first { v in
                guard v.beats <= remaining + 1e-6 else { return false }
                switch (v.base, v.dotted) {
                case (1, _): return multiple(p, of: 4) && abs(measure.lengthBeats - 4) < 1e-6
                case (2, _): return multiple(p, of: 1)
                case (4, _): return multiple(p, of: 0.5)
                case (8, _): return multiple(p, of: 0.25)
                default: return true
                }
            }
            let value = fits ?? .sixteenth
            result.append(value)
            p += value.beats
            remaining -= value.beats
            if result.count > 64 { break }
        }
        return result
    }

    // MARK: Ties, accidentals, beams, stems

    private mutating func linkTies() {
        for clef in [Clef.treble, .bass] {
            let indices = events.indices.filter { events[$0].clef == clef }
            for (a, b) in zip(indices, indices.dropFirst()) where events[b].isTieContinuation && !events[a].isRest {
                events[a].tiedTo = b
            }
        }
    }

    /// Letters the key signature sharpens (+1) or flattens (-1).
    public static func keyAlterations(keyFifths: Int) -> [String: Int] {
        var result: [String: Int] = [:]
        let sharps = ["F", "C", "G", "D", "A", "E", "B"]
        if keyFifths > 0 { for letter in sharps.prefix(min(7, keyFifths)) { result[letter] = 1 } }
        if keyFifths < 0 { for letter in sharps.reversed().prefix(min(7, -keyFifths)) { result[letter] = -1 } }
        return result
    }

    /// Writes a sharp, flat or natural where the note differs from the key signature or from the same
    /// line or space earlier in the measure.
    private mutating func writeAccidentals() {
        let key = Self.keyAlterations(keyFifths: keyFifths)
        var state: [Clef: [Int: Int]] = [:]
        var currentMeasure = -1
        for i in events.indices {
            if events[i].measureIndex != currentMeasure {
                currentMeasure = events[i].measureIndex
                state = [:]
            }
            let clef = events[i].clef
            for h in events[i].heads.indices {
                let head = events[i].heads[h]
                let step = head.staffStep
                let current = state[clef]?[step] ?? key[head.spelled.letter] ?? 0
                if head.spelled.accidental != current && !events[i].isTieContinuation {
                    events[i].heads[h].accidental = Accidental(rawValue: head.spelled.accidental)
                }
                state[clef, default: [:]][step] = head.spelled.accidental
            }
        }
    }

    /// Eighths and sixteenths within the same beat (a dotted quarter in 3/8, 6/8…) are beamed together.
    private mutating func findBeams() {
        var group: [Int] = []
        var groupKey: (clef: Clef, measure: Int, beat: Int)?
        func close() {
            if group.count >= 2 {
                for i in group { events[i].beam = beams.count }
                beams.append(group)
            }
            group = []
        }
        for clef in [Clef.treble, .bass] {
            groupKey = nil
            for i in events.indices where events[i].clef == clef {
                let event = events[i]
                let measure = measures[event.measureIndex]
                let signature = measure.timeSignature
                let unit = signature.beatType == 8 && signature.beats % 3 == 0 ? 1.5 : 1.0
                let key = (clef, event.measureIndex, Int(((event.gridBeat - measure.startBeat) / unit + 1e-6).rounded(.down)))
                guard !event.isRest, event.value.flags > 0 else {
                    close()
                    groupKey = nil
                    continue
                }
                if let current = groupKey, current.clef == key.0, current.measure == key.1, current.beat == key.2 {
                    group.append(i)
                } else {
                    close()
                    group = [i]
                    groupKey = key
                }
            }
            close()
        }
    }

    /// Stems point away from the staff's middle line: down when the notes (of the chord, or of the whole
    /// beamed group) sit on average above it.
    private mutating func chooseStems() {
        func up(_ indices: [Int]) -> Bool {
            let steps = indices.flatMap { events[$0].heads.map(\.staffStep) }
            guard let low = steps.min(), let high = steps.max(), let clef = indices.first.map({ events[$0].clef }) else {
                return true
            }
            let middle = Self.middleStep[clef] ?? 34
            // The note furthest from the middle line decides.
            return (middle - low) > (high - middle)
        }
        for i in events.indices where !events[i].isRest && events[i].beam == nil {
            events[i].stemUp = up([i])
        }
        for group in beams {
            let direction = up(group)
            for i in group { events[i].stemUp = direction }
        }
    }

    // MARK: - Looking up

    /// Indices of the events whose grid position is within `range` (events are sorted by it).
    public func eventIndices(inBeats range: ClosedRange<Double>) -> Range<Int> {
        var low = 0, high = events.count
        while low < high {
            let mid = (low + high) / 2
            if events[mid].gridBeat < range.lowerBound { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < events.count, events[end].gridBeat <= range.upperBound { end += 1 }
        return low..<end
    }

    /// The measure containing `beat`.
    public func measureIndex(atBeat beat: Double) -> Int? {
        guard !measures.isEmpty else { return nil }
        var low = 0, high = measures.count - 1
        if beat < measures[0].startBeat { return 0 }
        while low < high {
            let mid = (low + high + 1) / 2
            if measures[mid].startBeat <= beat + 1e-9 { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
