import XCTest
@testable import PianoCoachCore

// MARK: - Synthetic performances

/// A known piece written in beats, rendered to what a transcriber would hear from a real performance:
/// timing jitter, legato/staccato durations, uneven loudness, weak spurious notes, split fragments and
/// quiet overtone ghosts. Deterministic for a given seed.
struct SyntheticSong {
    struct Note {
        var midi: Int
        var beat: Double
        var beats: Double
        var hand: Hand
    }

    /// A rendered note that belongs to the piece, with the hand and beat it was written with.
    struct Truth {
        var midi: Int
        var start: Double
        var hand: Hand
        var beat: Double
    }

    var name: String
    var notes: [Note]
    var bpm: Double
    var beatsPerMeasure: Int
    var tonic: Int
    var isMinor: Bool
    var fifths: Int
    /// Beats before the first downbeat (an upbeat).
    var pickupBeats = 0.0

    /// Parses "E4 E4:0.5 C3+E3+G3:2 r:1 | ..." (a duration carries over until changed; "|" is ignored).
    static func part(_ text: String, hand: Hand, startBeat: Double = 0) -> [Note] {
        var beat = startBeat, length = 1.0
        var notes: [Note] = []
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) where token != "|" {
            let pieces = token.split(separator: ":")
            if pieces.count > 1 { length = Double(pieces[1])! }
            if pieces[0] != "r" {
                for name in pieces[0].split(separator: "+") {
                    notes.append(Note(midi: midi(String(name)), beat: beat, beats: length, hand: hand))
                }
            }
            beat += length
        }
        return notes
    }

    /// "C4" = 60, "F#3", "Bb2".
    static func midi(_ name: String) -> Int {
        let steps: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        var chars = Array(name)
        var value = steps[chars.removeFirst()]!
        if chars.first == "#" { value += 1; chars.removeFirst() }
        if chars.first == "b" { value -= 1; chars.removeFirst() }
        return (Int(String(chars))! + 1) * 12 + value
    }

    struct Imperfections {
        var eventJitter = 0.02
        var noteJitter = 0.005
        var durationRange = 0.8...1.2
        var spuriousRate = 0.03
        var fragmentRate = 0.04
        var ghostRate = 0.05
        var leadIn = 0.7
        /// How much longer the last beat is than the first (0.03 = gradually 3 % slower).
        var drift = 0.0

        static let none = Imperfections(eventJitter: 0, noteJitter: 0, durationRange: 1...1, spuriousRate: 0,
                                        fragmentRate: 0, ghostRate: 0)
    }

    func render(seed: UInt64 = 1, _ imperfections: Imperfections = Imperfections()) -> (notes: [TranscribedNote], truth: [Truth]) {
        var rng = SeededRandom(seed: seed)
        let spb = 60 / bpm
        let totalBeats = notes.map { $0.beat + $0.beats }.max() ?? 1
        func seconds(_ beat: Double) -> Double {
            imperfections.leadIn + spb * (beat + imperfections.drift * beat * beat / (2 * totalBeats))
        }
        var eventShift: [Double: Double] = [:]
        for beat in Set(notes.map(\.beat)).sorted() {
            eventShift[beat] = rng.uniform(-imperfections.eventJitter, imperfections.eventJitter)
        }
        var rendered: [(note: TranscribedNote, truth: Truth)] = []
        for n in notes.sorted(by: { ($0.beat, $0.midi) < ($1.beat, $1.midi) }) {
            let start = seconds(n.beat) + eventShift[n.beat]! + rng.uniform(-imperfections.noteJitter, imperfections.noteJitter)
            let length = (seconds(n.beat + n.beats) - seconds(n.beat))
                * rng.uniform(imperfections.durationRange.lowerBound, imperfections.durationRange.upperBound)
            let base = n.hand == .right ? 0.55 : 0.42
            let accent = isDownbeat(n.beat) ? 1.1 : 1
            let amplitude = base * accent * rng.uniform(0.85, 1.15)
            rendered.append((TranscribedNote(midi: n.midi, start: start, end: start + length, amplitude: amplitude),
                             Truth(midi: n.midi, start: start, hand: n.hand, beat: n.beat)))
        }
        // A transcriber hears one key at a time: a note ends where the same key sounds again.
        var notes = rendered.map(\.note)
        for i in notes.indices {
            if let next = notes[(i + 1)...].first(where: { $0.midi == notes[i].midi && $0.start > notes[i].start }) {
                notes[i].end = min(notes[i].end, next.start - 0.01)
            }
        }
        var output: [TranscribedNote] = []
        for n in notes {
            if n.duration > 0.3, rng.chance(imperfections.fragmentRate) {
                let cut = n.start + n.duration * rng.uniform(0.4, 0.7)
                output.append(TranscribedNote(midi: n.midi, start: n.start, end: cut, amplitude: n.amplitude))
                output.append(TranscribedNote(midi: n.midi, start: cut + rng.uniform(0, 0.02), end: n.end,
                                              amplitude: n.amplitude * rng.uniform(0.3, 0.55)))
            } else {
                output.append(n)
            }
            if rng.chance(imperfections.ghostRate) {
                // Overtone ghosts as Basic Pitch reports them on a recorded piano: mostly an octave up and
                // struck with the note, sometimes a twelfth or two octaves up, or appearing while it rings.
                let pick = rng.uniform(0, 1)
                let interval = pick < 0.6 ? 12 : pick < 0.8 ? 19 : 24
                let during = rng.chance(0.3)
                let start = during ? n.start + rng.uniform(0.1, 0.5) * n.duration : n.start + rng.uniform(-0.015, 0.015)
                let ratio = interval == 12 && !during ? rng.uniform(0.35, 0.55) : rng.uniform(0.25, 0.45)
                if n.midi + interval <= 108 {
                    output.append(TranscribedNote(midi: n.midi + interval, start: start,
                                                  end: start + (n.end - start) * rng.uniform(0.3, 0.9),
                                                  amplitude: n.amplitude * ratio))
                }
            }
        }
        let span = (notes.map(\.end).max() ?? 0)
        for _ in 0..<Int((Double(notes.count) * imperfections.spuriousRate).rounded()) {
            let near = notes[Int(rng.uniform(0, Double(notes.count) - 0.001))]
            let start = rng.uniform(imperfections.leadIn, span)
            output.append(TranscribedNote(midi: near.midi + Int(rng.uniform(-3, 3.999)), start: start,
                                          end: start + rng.uniform(0.05, 0.15), amplitude: rng.uniform(0.03, 0.09)))
        }
        return (output.sorted { ($0.start, $0.midi) < ($1.start, $1.midi) }, rendered.map(\.truth))
    }

    func isDownbeat(_ beat: Double) -> Bool {
        let x = (beat - pickupBeats) / Double(beatsPerMeasure)
        return abs(x - x.rounded()) < 1e-9
    }

    /// The piece with an upbeat of one note (`midi`, one beat) before its first measure.
    func withPickup(_ midi: Int) -> SyntheticSong {
        var song = self
        song.notes = notes.map { var n = $0; n.beat += 1; return n } + [Note(midi: midi, beat: 0, beats: 1, hand: .right)]
        song.pickupBeats = 1
        song.name += " with upbeat"
        return song
    }

    // MARK: Pieces

    /// "Ode to Joy" as in the app's demo: quarter-note melody (dipping to G3) over a bass in C.
    static func odeToJoy(bpm: Double = 96) -> SyntheticSong {
        let rh = """
        E4:1 E4 F4 G4 | G4 F4 E4 D4 | C4 C4 D4 E4 | E4:1.5 D4:0.5 D4:2 |
        E4:1 E4 F4 G4 | G4 F4 E4 D4 | C4 C4 D4 E4 | D4:1.5 C4:0.5 C4:2 |
        D4:1 D4 E4 C4 | D4 E4:0.5 F4 E4:1 C4 | D4 E4:0.5 F4 E4:1 D4 | C4 D4 G3:2 |
        E4:1 E4 F4 G4 | G4 F4 E4 D4 | C4 C4 D4 E4 | D4:1.5 C4:0.5 C4:2
        """
        let lh = """
        C3:4 | G2:4 | C3:4 | G2:2 G2:2 | C3:4 | G2:4 | C3:4 | G2:2 C3:2 |
        G2:2 C3:2 | G2:2 C3:2 | G2:2 C3:2 | C3:2 G2:2 | C3:4 | G2:4 | C3:4 | G2:2 C3:2
        """
        return SyntheticSong(name: "Ode to Joy", notes: part(rh, hand: .right) + part(lh, hand: .left), bpm: bpm,
                             beatsPerMeasure: 4, tonic: 0, isMinor: false, fifths: 0)
    }

    /// Two octaves of C major up and down in quarter notes over whole-note bass.
    static func cMajorScale(bpm: Double = 120) -> SyntheticSong {
        let up = ["C4", "D4", "E4", "F4", "G4", "A4", "B4", "C5", "D5", "E5", "F5", "G5", "A5", "B5", "C6"]
        let rh = (up + up.reversed().dropFirst()).joined(separator: ":1 ") + ":1 C4:3"
        let lh = "C3:4 G2:4 C3:4 F2:4 G2:4 C3:4 G2:4 C3:4"
        return SyntheticSong(name: "C major scale", notes: part(rh, hand: .right) + part(lh, hand: .left), bpm: bpm,
                             beatsPerMeasure: 4, tonic: 0, isMinor: false, fifths: 0)
    }

    /// A waltz in F major: melody over "oom-pah-pah" (bass, then a chord on beats 2 and 3).
    static func waltz(bpm: Double = 138) -> SyntheticSong {
        let rh = """
        C5:3 | A4:2 C5:1 | F5:3 | E5:2 D5:1 | C5:2 Bb4:1 | A4:2 G4:1 | A4:2 Bb4:1 | C5:3 |
        C5:3 | A4:2 C5:1 | F5:2 A5:1 | G5:2 F5:1 | E5:2 D5:1 | C5:2 E5:1 | F5:3 | F5:2 r:1
        """
        let chords = ["F": ("F2", "A3+C4"), "Bb": ("Bb2", "Bb3+D4"), "C": ("C3", "G3+Bb3")]
        let harmony = ["F", "F", "Bb", "C", "C", "F", "F", "C", "F", "F", "Bb", "C", "C", "C", "F", "F"]
        let lh = harmony.map { let c = chords[$0]!; return "\(c.0):1 \(c.1):1 \(c.1):1" }.joined(separator: " | ")
        return SyntheticSong(name: "Waltz in F", notes: part(rh, hand: .right) + part(lh, hand: .left), bpm: bpm,
                             beatsPerMeasure: 3, tonic: 5, isMinor: false, fifths: -1)
    }

    /// A folk-like tune in G major with eighth-note steps over half-note bass.
    static func gMajorTune(bpm: Double = 120) -> SyntheticSong {
        let rh = """
        G4:1 B4 D5 B4 | C5 E5 D5:2 | B4:0.5 C5 D5:1 G4 B4 | A4:3 r:1 |
        G4:1 B4 D5 B4 | C5 E5 D5 C5 | B4 A4:0.5 B4 A4:1 F#4 | G4:3 r:1 |
        D5:1 D5:0.5 E5 D5:1 B4 | C5 C5:0.5 D5 C5:1 A4 | B4 B4:0.5 C5 B4:1 G4 | A4 F#4 D4:2 |
        G4:1 B4 D5 B4 | C5 E5 D5 C5 | B4 A4 F#4 A4 | G4:4
        """
        let lh = """
        G2:2 D3 | C3 G2 | G2 E3 | D3 D2 | G2 D3 | C3 A2 | D3 D2 | G2 D3 |
        G2 B2 | A2 F#2 | G2 E2 | D2 D3 | G2 B2 | C3 A2 | D3 D2 | G2:4
        """
        return SyntheticSong(name: "Tune in G", notes: part(rh, hand: .right) + part(lh, hand: .left), bpm: bpm,
                             beatsPerMeasure: 4, tonic: 7, isMinor: false, fifths: 1)
    }

    /// A slow piece in E minor (with the raised D♯) over quarter-note broken chords.
    static func eMinorPiece(bpm: Double = 72) -> SyntheticSong {
        let rh = """
        E5:1 B4 G4 B4 | E5:2 D#5 | E5:1 F#5 G5 F#5 | E5:4 |
        G5:1 F#5 E5 D#5 | E5:2 B4 | C5:1 B4 A4 F#4 | E4:4 |
        E4:1 G4 B4 E5 | D#5:2 B4 | C5:1 A4 F#4 D#4 | E4:4
        """
        let lh = """
        E2:1 B2 E3 B2 | B1 F#2 B2 F#2 | E2 B2 E3 B2 | E2 B2 G3:2 |
        E2:1 B2 E3 B2 | E2 G2 B2 G2 | A2 E3 B1 F#2 | E2:4 |
        E2:1 B2 E3 G3 | B1 F#2 B2 A2 | A2 E3 B1 F#2 | E2:4
        """
        return SyntheticSong(name: "Piece in E minor", notes: part(rh, hand: .right) + part(lh, hand: .left), bpm: bpm,
                             beatsPerMeasure: 4, tonic: 4, isMinor: true, fifths: 1)
    }

    /// A tune in B♭ major.
    static func bFlatTune(bpm: Double = 96) -> SyntheticSong {
        let rh = """
        F4:1 Bb4 D5 Bb4 | C5 Eb5 D5:2 | Bb4:1 C5 D5 Eb5 | F5:3 r:1 |
        G5:1 F5 Eb5 D5 | C5 D5:0.5 Eb5 C5:1 A4 | Bb4 D5 C5 A4 | Bb4:4 |
        F4:1 Bb4 D5 Bb4 | C5 Eb5 D5:2 | Bb4:1 C5 D5 Eb5 | F5:3 r:1 |
        G5:1 F5 Eb5 D5 | C5 D5:0.5 Eb5 C5:1 A4 | Bb4 D5 C5 A4 | Bb4:4
        """
        let lh = """
        Bb2:2 F3 | Eb3 Bb2 | G2 Eb3 | F2 F3 | Eb3 Bb2 | F2 F3 | D3 F3 | Bb2:4 |
        Bb2:2 F3 | Eb3 Bb2 | G2 Eb3 | F2 F3 | Eb3 Bb2 | F2 F3 | D3 F3 | Bb2:4
        """
        return SyntheticSong(name: "Tune in B♭", notes: part(rh, hand: .right) + part(lh, hand: .left), bpm: bpm,
                             beatsPerMeasure: 4, tonic: 10, isMinor: false, fifths: -2)
    }

    /// Hands that cross middle C both ways: the melody walks down to G3 over a low bass, then the left
    /// hand's broken chords climb to G4 under a high melody.
    static func crossingPiece(bpm: Double = 100) -> SyntheticSong {
        let rh = """
        E5:1 D5 C5 B4 | A4 G4 F4 E4 | D4 C4 B3 A3 | G3:2 C4 |
        C6:1 B5 A5 G5 | E6 D6 C6:2 | G5:1 A5 B5 C6 | C6:4 |
        G4:1 E4 C4 A3 | B3 D4 G4 F4 | E4 C4 A3 G3 | C4:4
        """
        let lh = """
        C2:2 G2 | F2 C2 | F2 D2 | G1 C2 |
        C3:1 G3 C4 E4 | G3 C4 E4 G4 | G3 D4 F4 G4 | C4 E4 G4:2 |
        C2:2 E2 | G1 G2 | A1 E2 | C2:4
        """
        return SyntheticSong(name: "Crossing", notes: part(rh, hand: .right) + part(lh, hand: .left), bpm: bpm,
                             beatsPerMeasure: 4, tonic: 0, isMinor: false, fifths: 0)
    }

    static var all: [SyntheticSong] {
        [odeToJoy(bpm: 96), odeToJoy(bpm: 72), cMajorScale(bpm: 120), waltz(bpm: 138), gMajorTune(bpm: 120),
         eMinorPiece(bpm: 72), bFlatTune(bpm: 96), crossingPiece(bpm: 100)]
    }
}

/// SplitMix64: small, fast and the same on every platform.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * Double(next() >> 11) / Double(1 << 53)
    }

    mutating func chance(_ p: Double) -> Bool { uniform(0, 1) < p }
}

/// How an arranged song compares with the piece it was rendered from.
struct ArrangementReport {
    var tempoError: Double
    var matched: Int
    var truthCount: Int
    var extra: Int
    var handAccuracy: Double
    /// Seconds between each matched note's rendered onset and where its beat maps back to.
    var meanTimingError: Double
    var maxTimingError: Double
    /// Share of the piece's downbeats that land on a measure start of the arrangement.
    var downbeatAccuracy: Double

    var recall: Double { Double(matched) / Double(max(1, truthCount)) }

    init(_ song: ArrangedSong, truth: [SyntheticSong.Truth], piece: SyntheticSong) {
        tempoError = abs(song.tempoBPM / piece.bpm - 1)
        truthCount = truth.count
        var used = Set<Int>()
        var correct = 0, errors: [Double] = []
        var downbeats = 0, downbeatsHit = 0
        let bars = song.score.measures.map(\.startBeat)
        for t in truth {
            let candidates = song.score.notes.indices.filter { !used.contains($0) && song.score.notes[$0].midi == t.midi }
            guard let best = candidates.min(by: {
                abs(song.seconds(atBeat: song.score.notes[$0].beat) - t.start)
                    < abs(song.seconds(atBeat: song.score.notes[$1].beat) - t.start)
            }) else { continue }
            let error = abs(song.seconds(atBeat: song.score.notes[best].beat) - t.start)
            guard error < 0.08 else { continue }
            used.insert(best)
            errors.append(error)
            if song.score.notes[best].hand == t.hand { correct += 1 }
            if piece.isDownbeat(t.beat) {
                downbeats += 1
                let beat = song.score.notes[best].beat
                if bars.contains(where: { abs($0 - beat) < 0.15 }) { downbeatsHit += 1 }
            }
        }
        matched = used.count
        extra = song.score.notes.count - matched
        handAccuracy = Double(correct) / Double(max(1, matched))
        meanTimingError = errors.reduce(0, +) / Double(max(1, errors.count))
        maxTimingError = errors.max() ?? 0
        downbeatAccuracy = Double(downbeatsHit) / Double(max(1, downbeats))
    }
}

// MARK: - Tests

final class SongArrangerTests: XCTestCase {
    // MARK: Whole songs

    func testClearPiecesComeOutRight() throws {
        for piece in SyntheticSong.all {
            for seed: UInt64 in 1...2 {
                let (notes, truth) = piece.render(seed: seed)
                let song = try XCTUnwrap(SongArranger.arrange(notes, title: piece.name))
                let r = ArrangementReport(song, truth: truth, piece: piece)
                let label = "\(piece.name) at \(piece.bpm) BPM, seed \(seed)"
                XCTAssertLessThan(r.tempoError, 0.04, label)
                XCTAssertEqual(song.keyFifths, piece.fifths, label)
                XCTAssertEqual(song.isMinor, piece.isMinor, label)
                XCTAssertEqual(song.timeSignature, TimeSignature(beats: piece.beatsPerMeasure, beatType: 4), label)
                XCTAssertGreaterThanOrEqual(r.handAccuracy, piece.name == "Crossing" ? 0.85 : 0.95, label)
                XCTAssertGreaterThanOrEqual(r.recall, 0.97, label)
                XCTAssertLessThanOrEqual(Double(r.extra), 0.03 * Double(r.truthCount), label)
                XCTAssertLessThan(r.meanTimingError, 0.005, label)
                XCTAssertLessThan(r.maxTimingError, 0.03, label)
                XCTAssertGreaterThanOrEqual(r.downbeatAccuracy, 0.9, label)
                assertWellFormed(song, label)
            }
        }
    }

    func testKeyNames() throws {
        let expected = ["Ode to Joy": "C major", "C major scale": "C major", "Waltz in F": "F major",
                        "Tune in G": "G major", "Piece in E minor": "E minor", "Tune in B♭": "B♭ major"]
        for piece in SyntheticSong.all {
            guard let name = expected[piece.name] else { continue }
            XCTAssertEqual(SongArranger.arrange(piece.render(seed: 3).notes, title: "")?.keyName, name, piece.name)
        }
    }

    func testHeavierImperfections() throws {
        let heavy = SyntheticSong.Imperfections(eventJitter: 0.03, noteJitter: 0.008, durationRange: 0.6...1.4,
                                                spuriousRate: 0.06, fragmentRate: 0.08, ghostRate: 0.1)
        for piece in [SyntheticSong.odeToJoy(), .gMajorTune(), .eMinorPiece(), .crossingPiece()] {
            let (notes, truth) = piece.render(seed: 11, heavy)
            let song = try XCTUnwrap(SongArranger.arrange(notes, title: piece.name))
            let r = ArrangementReport(song, truth: truth, piece: piece)
            XCTAssertLessThan(r.tempoError, 0.04, piece.name)
            XCTAssertEqual(song.keyFifths, piece.fifths, piece.name)
            XCTAssertGreaterThanOrEqual(r.handAccuracy, 0.9, piece.name)
            XCTAssertGreaterThanOrEqual(r.recall, 0.95, piece.name)
            XCTAssertLessThanOrEqual(Double(r.extra), 0.06 * Double(r.truthCount), piece.name)
            assertWellFormed(song, piece.name)
        }
    }

    func testUpbeatBecomesALeadInToTheFirstMeasure() throws {
        let piece = SyntheticSong.odeToJoy(bpm: 108).withPickup(62)
        let (notes, truth) = piece.render(seed: 5)
        let song = try XCTUnwrap(SongArranger.arrange(notes, title: piece.name))
        let r = ArrangementReport(song, truth: truth, piece: piece)
        XCTAssertLessThan(r.tempoError, 0.04)
        XCTAssertGreaterThanOrEqual(r.downbeatAccuracy, 0.95)
        let first = try XCTUnwrap(song.score.notes.first)
        XCTAssertEqual(first.midi, 62)
        XCTAssertEqual(first.measureIndex, 0)
        XCTAssertEqual(first.beat, 3, accuracy: 0.1)   // the upbeat is the last beat of measure 1
        assertWellFormed(song, piece.name)
    }

    func testDriftingTempoKeepsTheRecordingsTiming() throws {
        var drifting = SyntheticSong.Imperfections()
        drifting.drift = 0.04
        let piece = SyntheticSong.gMajorTune()
        let (notes, truth) = piece.render(seed: 2, drifting)
        let song = try XCTUnwrap(SongArranger.arrange(notes, title: piece.name))
        let average = 60 * (truth.last!.beat - truth.first!.beat) / (truth.last!.start - truth.first!.start)
        XCTAssertEqual(song.tempoBPM / average, 1, accuracy: 0.02)
        XCTAssertLessThan(ArrangementReport(song, truth: truth, piece: piece).meanTimingError, 0.005)
        assertTimingIsExact(song, cleaned: SongArranger.cleanUp(notes, options: .init()))
    }

    /// Beats are a straight rescaling of the recording: every note ends exactly where it did, and every
    /// note struck on its own starts exactly where it did.
    func testTimingIsALinearMapOfTheRecording() throws {
        for piece in [SyntheticSong.odeToJoy(bpm: 72), .waltz(), .crossingPiece()] {
            let notes = piece.render(seed: 4).notes
            let song = try XCTUnwrap(SongArranger.arrange(notes, title: piece.name))
            assertTimingIsExact(song, cleaned: SongArranger.cleanUp(notes, options: .init()))
            XCTAssertEqual(song.beat(atSeconds: song.seconds(atBeat: 12.34)), 12.34, accuracy: 1e-9)
        }
    }

    func testForcedTempoAndTimeSignature() throws {
        let piece = SyntheticSong.odeToJoy(bpm: 96)
        let notes = piece.render(seed: 1).notes
        var options = SongArranger.Options()
        options.tempoBPM = 48
        options.timeSignature = TimeSignature(beats: 2, beatType: 4)
        let song = try XCTUnwrap(SongArranger.arrange(notes, title: piece.name, options: options))
        XCTAssertEqual(song.tempoBPM, 48)
        XCTAssertEqual(song.score.initialTempoBPM, 48)
        XCTAssertEqual(song.timeSignature, TimeSignature(beats: 2, beatType: 4))
        XCTAssertEqual(song.score.measures[1].startBeat, 2)
        // Half the tempo and two beats a measure: the piece's measures still line up with the song's.
        let report = ArrangementReport(song, truth: piece.render(seed: 1).truth, piece: piece)
        XCTAssertEqual(report.matched, report.truthCount)
        XCTAssertGreaterThanOrEqual(report.downbeatAccuracy, 0.9)
        assertWellFormed(song, "forced")
    }

    func testChartAndMIDIFileOfTheSong() throws {
        let song = try XCTUnwrap(SongArranger.arrange(SyntheticSong.bFlatTune().render(seed: 1).notes, title: "Tune"))
        let chart = try XCTUnwrap(song.chart)
        XCTAssertEqual(chart.title, "Tune")
        XCTAssertEqual(chart.source, .listening)
        XCTAssertEqual(chart.beatsPerMinute, song.tempoBPM)
        XCTAssertEqual(chart.keyFifths, -2)
        XCTAssertEqual(chart.videoTimeOfBeatZero ?? -1, song.timeOfBeatZero, accuracy: 1e-12)
        XCTAssertEqual(chart.barLines, song.score.measures.map(\.startBeat))
        XCTAssertTrue(chart.notes.allSatisfy { ($0.velocity ?? 0) >= 0.25 && ($0.velocity ?? 2) <= 1 })
        let parsed = try MIDIFileParser.parse(data: song.midiFileData)
        XCTAssertEqual(parsed.notes.count, song.noteCount)
        XCTAssertEqual(parsed.keyFifths, -2)
    }

    func testLouderNotesPlayLouder() {
        XCTAssertEqual(SongArranger.velocity(amplitude: 0.5, reference: 0.5), 0.7, accuracy: 1e-12)
        XCTAssertLessThan(SongArranger.velocity(amplitude: 0.3, reference: 0.5), 0.7)
        XCTAssertGreaterThan(SongArranger.velocity(amplitude: 0.7, reference: 0.5), 0.7)
        XCTAssertEqual(SongArranger.velocity(amplitude: 0.01, reference: 0.5), 0.25)
        XCTAssertEqual(SongArranger.velocity(amplitude: 1, reference: 0.3), 1)
        XCTAssertEqual(SongArranger.velocity(amplitude: 0.4, reference: 0), 0.7)
    }

    // MARK: Real transcriptions

    /// Basic Pitch's notes for "Ode to Joy" (melody and half-note bass, 100 BPM) played on the app's
    /// recorded piano: the realistic case. Every real note survives, no overtone ghost does, and what is
    /// left over is only held bass notes the transcriber heard struck again.
    func testRecordedPianoTranscription() throws {
        let song = try XCTUnwrap(SongArranger.arrange(BasicPitchOde.recordedPiano, title: "Ode"))
        XCTAssertEqual(song.tempoBPM, 100, accuracy: 1)
        XCTAssertEqual(song.keyName, "C major")
        XCTAssertEqual(song.timeSignature, .common)
        let result = BasicPitchOde.compare(song)
        XCTAssertEqual(result.found, BasicPitchOde.truth.count)
        XCTAssertGreaterThanOrEqual(result.rightHand, result.found - 1)
        for extra in result.extras {
            let time = song.seconds(atBeat: extra.beat)
            XCTAssertTrue(BasicPitchOde.truth.contains { $0.midi == extra.midi && $0.start < time && $0.end > time },
                          "\(extra.midi) at \(time)s is not a held note struck again")
        }
        XCTAssertLessThanOrEqual(result.extras.count, 8)
    }

    /// The same song on a simple additive synthesizer, whose strong partials make Basic Pitch report 70
    /// overtone ghosts next to the 46 real notes, some as loud as real notes on a recorded piano: no real
    /// note may be lost, and more than half the ghosts go.
    func testAdditiveSynthTranscriptionKeepsEveryRealNote() throws {
        let song = try XCTUnwrap(SongArranger.arrange(BasicPitchOde.additiveSynth, title: "Ode"))
        XCTAssertEqual(song.tempoBPM, 100, accuracy: 1)
        XCTAssertEqual(song.keyName, "C major")
        let result = BasicPitchOde.compare(song)
        XCTAssertEqual(result.found, BasicPitchOde.truth.count)
        XCTAssertLessThanOrEqual(result.extras.count, 30)
    }

    // MARK: Cleanup

    func testOvertoneGhostsAreRemovedWithoutLosingRealNotes() {
        var rng = SeededRandom(seed: 99)
        let piece = SyntheticSong.odeToJoy(bpm: 100)
        var real: [TranscribedNote] = []
        var ghosts: [TranscribedNote] = []
        for n in piece.notes {
            let start = 0.5 + n.beat * 0.6 + rng.uniform(-0.01, 0.01)
            let note = TranscribedNote(midi: n.midi, start: start, end: start + n.beats * 0.6 * 0.9,
                                       amplitude: rng.uniform(0.65, 0.75))
            real.append(note)
            for (interval, level) in [(12, 0.4), (24, 0.3)] {
                let ghostStart = start + rng.uniform(-0.02, 0.02)
                ghosts.append(TranscribedNote(midi: n.midi + interval, start: ghostStart,
                                              end: ghostStart + (note.end - ghostStart) * rng.uniform(0.5, 1),
                                              amplitude: level * rng.uniform(0.9, 1.1)))
            }
        }
        let cleaned = SongArranger.cleanUp(real + ghosts, options: .init())
        for n in real {
            XCTAssertTrue(cleaned.contains { $0.midi == n.midi && abs($0.start - n.start) <= 0.025 },
                          "lost real note \(n.midi) at \(n.start)")
        }
        let leftover = cleaned.filter { c in !real.contains { $0.midi == c.midi && abs($0.start - c.start) <= 0.025 } }
        XCTAssertLessThanOrEqual(Double(leftover.count), 0.05 * Double(ghosts.count))
    }

    func testGenuineOctavesAndMelodyOverHeldBassAreKept() {
        let notes = [
            TranscribedNote(midi: 48, start: 1, end: 2, amplitude: 0.7),       // octave struck together
            TranscribedNote(midi: 60, start: 1, end: 2, amplitude: 0.7),
            TranscribedNote(midi: 43, start: 3, end: 6, amplitude: 0.8),       // held bass...
            TranscribedNote(midi: 55, start: 4, end: 4.5, amplitude: 0.62),    // ...an octave above it, later
            TranscribedNote(midi: 67, start: 5, end: 5.4, amplitude: 0.62),    // ...two octaves above it, later
            TranscribedNote(midi: 62, start: 5.5, end: 5.9, amplitude: 0.4),   // ...a ghost appearing as it rings
            TranscribedNote(midi: 50, start: 7, end: 8, amplitude: 0.72),      // a real note a twelfth up, softer
            TranscribedNote(midi: 69, start: 7, end: 8, amplitude: 0.44),
            TranscribedNote(midi: 36, start: 9, end: 10, amplitude: 0.8),      // octave ghost: removed
            TranscribedNote(midi: 48, start: 9.01, end: 9.8, amplitude: 0.45),
        ]
        let cleaned = SongArranger.cleanUp(notes, options: .init())
        XCTAssertEqual(cleaned.map(\.midi), [48, 60, 43, 55, 67, 50, 69, 36])
    }

    func testFragmentsAreJoinedButRepeatedNotesKept() {
        let notes = [
            TranscribedNote(midi: 60, start: 0, end: 0.5, amplitude: 0.7),       // split by the transcriber
            TranscribedNote(midi: 60, start: 0.51, end: 1.0, amplitude: 0.3),
            TranscribedNote(midi: 64, start: 2, end: 2.5, amplitude: 0.7),       // played twice
            TranscribedNote(midi: 64, start: 2.5, end: 3, amplitude: 0.68),
            TranscribedNote(midi: 67, start: 4, end: 4.5, amplitude: 0.7),       // played twice, softer, in a chord
            TranscribedNote(midi: 67, start: 4.5, end: 5, amplitude: 0.35),
            TranscribedNote(midi: 71, start: 4.505, end: 5, amplitude: 0.6),
            TranscribedNote(midi: 62, start: 6, end: 7, amplitude: 0.6),         // overlapping duplicate
            TranscribedNote(midi: 62, start: 6.01, end: 6.5, amplitude: 0.7),
            TranscribedNote(midi: 65, start: 8, end: 9, amplitude: 0.6),         // overlaps its own repeat
            TranscribedNote(midi: 65, start: 8.5, end: 9.5, amplitude: 0.6),
        ]
        let cleaned = SongArranger.cleanUp(notes, options: .init())
        let summary = cleaned.map { "\($0.midi)@\($0.start)-\($0.end)" }
        XCTAssertEqual(summary, ["60@0.0-1.0", "64@2.0-2.5", "64@2.5-3.0", "67@4.0-4.5", "67@4.5-5.0", "71@4.505-5.0",
                                 "62@6.0-7.0", "65@8.0-8.5", "65@8.5-9.5"])
        XCTAssertEqual(cleaned.first { $0.midi == 62 }?.amplitude, 0.7)
    }

    func testNoiseIsDroppedButSoftNotesKept() {
        var notes = (0..<20).map { TranscribedNote(midi: 60 + $0 % 12, start: Double($0), end: Double($0) + 0.5, amplitude: 0.7) }
        notes += [
            TranscribedNote(midi: 50, start: 30, end: 30.5, amplitude: 0.25),    // soft but real (0.36 of median)
            TranscribedNote(midi: 52, start: 31, end: 31.5, amplitude: 0.1),     // noise
            TranscribedNote(midi: 53, start: 32, end: 32.03, amplitude: 0.7),    // a click
            TranscribedNote(midi: 20, start: 33, end: 34, amplitude: 0.7),       // below the piano
            TranscribedNote(midi: 109, start: 33, end: 34, amplitude: 0.7),      // above the piano
            TranscribedNote(midi: 21, start: 35, end: 36, amplitude: 0.7),       // lowest key
            TranscribedNote(midi: 108, start: 37, end: 38, amplitude: 0.7),      // highest key
            TranscribedNote(midi: 55, start: .nan, end: 1, amplitude: 0.7),
            TranscribedNote(midi: 56, start: 2, end: 1, amplitude: 0.7),
        ]
        let kept = SongArranger.cleanUp(notes, options: .init()).map(\.midi)
        XCTAssertEqual(kept.count, 23)
        XCTAssertTrue(kept.contains(50))
        XCTAssertTrue(kept.contains(21) && kept.contains(108))
        XCTAssertFalse([52, 53, 20, 109, 55, 56].contains { kept.contains($0) })
    }

    // MARK: Degenerate input

    func testNothingUsable() {
        XCTAssertNil(SongArranger.arrange([], title: "Empty"))
        XCTAssertNil(SongArranger.arrange([TranscribedNote(midi: 10, start: 0, end: 1, amplitude: 1),
                                           TranscribedNote(midi: 60, start: 0, end: 0.01, amplitude: 1)], title: "Noise"))
    }

    func testOneNote() throws {
        let song = try XCTUnwrap(SongArranger.arrange([TranscribedNote(midi: 60, start: 2.5, end: 3.1, amplitude: 0.6)],
                                                      title: "One"))
        XCTAssertEqual(song.noteCount, 1)
        XCTAssertEqual(song.tempoBPM, 100)
        XCTAssertEqual(song.score.notes[0].beat, 0)
        XCTAssertEqual(song.score.notes[0].durationBeats, 1, accuracy: 1e-9)
        XCTAssertEqual(song.seconds(atBeat: 0), 2.5, accuracy: 1e-12)
        XCTAssertEqual(song.score.measures.count, 1)
        assertWellFormed(song, "one note")
    }

    func testOneChord() throws {
        let chord = [48, 52, 55, 60, 64, 67, 72].map { TranscribedNote(midi: $0, start: 1, end: 2, amplitude: 0.6) }
        let song = try XCTUnwrap(SongArranger.arrange(chord, title: "Chord"))
        XCTAssertEqual(song.score.events.count, 1)
        XCTAssertEqual(song.score.events[0].pitches, [48, 52, 55, 60, 64, 67, 72])
        XCTAssertEqual(Set(song.score.notes.map(\.hand)), [.left, .right])
        assertWellFormed(song, "one chord")
    }

    func testVeryLongNotesAndExtremeRegisters() throws {
        let notes = [
            TranscribedNote(midi: 21, start: 0, end: 30, amplitude: 0.6),
            TranscribedNote(midi: 108, start: 0, end: 30, amplitude: 0.6),
            TranscribedNote(midi: 60, start: 10, end: 12, amplitude: 0.6),
            TranscribedNote(midi: 62, start: 20, end: 40, amplitude: 0.6),
        ]
        let song = try XCTUnwrap(SongArranger.arrange(notes, title: "Long"))
        XCTAssertEqual(song.noteCount, 4)
        XCTAssertEqual(song.score.notes.first { $0.midi == 21 }?.hand, .left)
        XCTAssertEqual(song.score.notes.first { $0.midi == 108 }?.hand, .right)
        XCTAssertEqual(song.seconds(atBeat: song.score.notes.map { $0.beat + $0.durationBeats }.max()!), 40, accuracy: 1e-9)
        assertWellFormed(song, "long notes")
    }

    // MARK: Checks

    func assertWellFormed(_ song: ArrangedSong, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let score = song.score
        XCTAssertEqual(score.initialTempoBPM, song.tempoBPM, label, file: file, line: line)
        XCTAssertEqual(score.keyFifths, song.keyFifths, label, file: file, line: line)
        XCTAssertEqual(song.noteCount, score.notes.count, label, file: file, line: line)
        let length = song.timeSignature.quarterBeatsPerMeasure
        for (i, m) in score.measures.enumerated() {
            XCTAssertEqual(m.index, i, label, file: file, line: line)
            XCTAssertEqual(m.sourceIndex, i, label, file: file, line: line)
            XCTAssertEqual(m.number, String(i + 1), label, file: file, line: line)
            XCTAssertEqual(m.startBeat, Double(i) * length, accuracy: 1e-9, label, file: file, line: line)
            XCTAssertEqual(m.lengthBeats, length, label, file: file, line: line)
            XCTAssertEqual(m.timeSignature, song.timeSignature, label, file: file, line: line)
        }
        let end = score.notes.map { $0.beat + $0.durationBeats }.max() ?? 0
        XCTAssertGreaterThanOrEqual(score.totalBeats + 1.0 / 960, end, label, file: file, line: line)
        XCTAssertLessThan(score.totalBeats - length, max(end, score.events.last?.beat ?? 0) + 1e-9, label, file: file, line: line)

        for (k, e) in score.events.enumerated() {
            XCTAssertEqual(e.index, k, label, file: file, line: line)
            XCTAssertGreaterThanOrEqual(e.beat, 0, label, file: file, line: line)
            if k > 0 { XCTAssertGreaterThan(e.beat, score.events[k - 1].beat, label, file: file, line: line) }
            XCTAssertEqual(e.pitches, Array(Set(e.pitches)).sorted(), label, file: file, line: line)
            let m = score.measures[e.measureIndex]
            XCTAssertTrue(m.startBeat <= e.beat + 1e-9 && e.beat < m.endBeat, label, file: file, line: line)
            XCTAssertEqual(e.sourceMeasureIndex, e.measureIndex, label, file: file, line: line)
            XCTAssertEqual(e.beatInMeasure, e.beat - m.startBeat, accuracy: 1e-9, label, file: file, line: line)
            let members = score.notes.filter { $0.beat == e.beat }
            XCTAssertEqual(members.map(\.midi), e.pitches, label, file: file, line: line)
            let expected = k + 1 < score.events.count ? score.events[k + 1].beat - e.beat : members.map(\.durationBeats).max()!
            XCTAssertEqual(e.durationBeats, expected, accuracy: 1e-9, label, file: file, line: line)
        }
        XCTAssertEqual(score.notes.count, score.events.reduce(0) { $0 + $1.pitches.count }, label, file: file, line: line)
        for (a, b) in zip(score.notes, score.notes.dropFirst()) {
            XCTAssertTrue((a.beat, a.midi) < (b.beat, b.midi), label, file: file, line: line)
        }
        for n in score.notes {
            XCTAssertGreaterThan(n.durationBeats, 0, label, file: file, line: line)
            XCTAssertEqual(score.measureIndex(atBeat: n.beat), n.measureIndex, label, file: file, line: line)
            XCTAssertTrue((0.25...1).contains(n.velocity ?? -1), label, file: file, line: line)
        }
    }

    /// Every note ends exactly where the cleaned transcription says, and notes struck on their own start
    /// exactly there too (chord notes share their group's first onset).
    func assertTimingIsExact(_ song: ArrangedSong, cleaned: [TranscribedNote], file: StaticString = #filePath,
                             line: UInt = #line) {
        for event in song.score.events {
            for n in song.score.notes where n.beat == event.beat {
                let start = song.seconds(atBeat: n.beat), end = song.seconds(atBeat: n.beat + n.durationBeats)
                guard let source = cleaned.first(where: { $0.midi == n.midi && abs($0.end - end) < 1e-6 }) else {
                    return XCTFail("no transcribed note ends where \(n.midi) at beat \(n.beat) does", file: file, line: line)
                }
                XCTAssertGreaterThanOrEqual(source.start - start, -1e-6, file: file, line: line)
                XCTAssertLessThan(source.start - start, 0.05, file: file, line: line)
                if event.pitches.count == 1 {
                    XCTAssertEqual(start, source.start, accuracy: 1e-6, file: file, line: line)
                }
            }
        }
    }
}

// MARK: - Real Basic Pitch output

/// Basic Pitch (the reference ONNX model and note decoding, default thresholds) on "Ode to Joy" as
/// rendered for this app: melody plus a half-note bass at 100 BPM, 46 notes. `midi start end amplitude`.
enum BasicPitchOde {
    static func notes(_ text: String) -> [TranscribedNote] {
        text.split(separator: ",").map { item in
            let v = item.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { Double($0)! }
            return TranscribedNote(midi: Int(v[0]), start: v[1], end: v[2], amplitude: v[3])
        }
    }

    /// Real notes found (onset within 80 ms), how many of them got the right hand (bass = left), and the
    /// song's notes that match nothing.
    static func compare(_ song: ArrangedSong) -> (found: Int, rightHand: Int, extras: [ScoreNote]) {
        var used = Set<Int>(), found = 0, rightHand = 0
        for t in truth {
            let candidates = song.score.notes.indices.filter {
                !used.contains($0) && song.score.notes[$0].midi == t.midi
                    && abs(song.seconds(atBeat: song.score.notes[$0].beat) - t.start) < 0.08
            }
            guard let i = candidates.first else { continue }
            used.insert(i)
            found += 1
            if song.score.notes[i].hand == (t.midi < 55 ? .left : .right) { rightHand += 1 }
        }
        return (found, rightHand, song.score.notes.indices.filter { !used.contains($0) }.map { song.score.notes[$0] })
    }

    static let truth = notes("""
        48 0.500 1.580 0.600, 64 0.500 1.040 0.800, 64 1.100 1.640 0.800, 48 1.700 2.780 0.600, 65 1.700 2.240 0.800, 67 2.300 2.840 0.800,
        43 2.900 3.980 0.600, 67 2.900 3.440 0.800, 65 3.500 4.040 0.800, 43 4.100 5.180 0.600, 64 4.100 4.640 0.800, 62 4.700 5.240 0.800,
        48 5.300 6.380 0.600, 60 5.300 5.840 0.800, 60 5.900 6.440 0.800, 62 6.500 7.040 0.800, 48 6.500 7.580 0.600, 64 7.100 7.640 0.800,
        64 7.700 8.510 0.800, 43 7.700 8.780 0.600, 62 8.600 8.870 0.800, 62 8.900 9.980 0.800, 43 8.900 9.980 0.600, 64 10.100 10.640 0.800,
        48 10.100 11.180 0.600, 64 10.700 11.240 0.800, 65 11.300 11.840 0.800, 48 11.300 12.380 0.600, 67 11.900 12.440 0.800, 67 12.500 13.040 0.800,
        43 12.500 13.580 0.600, 65 13.100 13.640 0.800, 64 13.700 14.240 0.800, 43 13.700 14.780 0.600, 62 14.300 14.840 0.800, 60 14.900 15.440 0.800,
        48 14.900 15.980 0.600, 60 15.500 16.040 0.800, 62 16.100 16.640 0.800, 48 16.100 17.180 0.600, 64 16.700 17.240 0.800, 62 17.300 18.110 0.800,
        48 17.300 18.380 0.600, 60 18.200 18.470 0.800, 60 18.500 19.580 0.800, 48 18.500 19.580 0.600
        """)

    static let recordedPiano = notes("""
        64 0.499 1.115 0.643, 48 0.511 1.115 0.778, 60 0.511 1.207 0.377, 48 1.115 1.718 0.705, 64 1.115 1.707 0.703, 48 1.718 2.300 0.738,
        60 1.718 1.974 0.350, 65 1.718 2.265 0.583, 48 2.300 2.869 0.716, 67 2.300 2.904 0.607, 43 2.904 4.101 0.733, 55 2.904 3.101 0.336,
        67 2.904 3.473 0.445, 65 3.519 4.101 0.636, 43 4.101 5.262 0.727, 64 4.101 4.658 0.599, 62 4.693 5.308 0.609, 48 5.308 5.912 0.731,
        60 5.308 5.912 0.560, 48 5.912 6.505 0.632, 60 5.912 6.587 0.669, 48 6.505 7.666 0.688, 62 6.505 7.109 0.668, 64 7.109 7.713 0.674,
        64 7.713 8.515 0.570, 43 7.771 8.898 0.714, 62 8.597 8.910 0.682, 43 8.898 10.072 0.744, 62 8.910 10.072 0.432, 48 10.107 10.711 0.781,
        60 10.107 10.815 0.375, 64 10.107 10.711 0.641, 48 10.711 11.303 0.715, 64 10.711 11.291 0.712, 65 11.291 11.872 0.597, 48 11.303 11.918 0.743,
        60 11.303 11.570 0.404, 67 11.907 12.500 0.607, 48 11.918 12.477 0.712, 43 12.500 13.719 0.728, 55 12.500 12.709 0.333, 67 12.500 13.057 0.451,
        65 13.104 13.707 0.638, 64 13.707 14.266 0.600, 43 13.719 14.870 0.717, 62 14.301 14.905 0.606, 48 14.905 15.508 0.731, 60 14.905 15.508 0.557,
        48 15.508 16.102 0.632, 60 15.508 16.206 0.658, 48 16.102 17.309 0.705, 62 16.102 16.705 0.687, 64 16.705 17.309 0.689, 48 17.309 18.204 0.712,
        62 17.309 18.181 0.687, 48 18.204 18.495 0.519, 60 18.204 18.506 0.745, 48 18.495 19.760 0.722, 60 18.506 19.725 0.518
        """)

    static let additiveSynth = notes("""
        48 0.499 1.718 0.789, 64 0.499 1.103 0.783, 76 0.499 1.091 0.541, 60 0.511 1.103 0.439, 92 0.522 0.778 0.317, 76 1.091 1.672 0.523,
        60 1.103 1.718 0.404, 64 1.103 1.707 0.773, 92 1.138 1.463 0.308, 77 1.695 2.277 0.494, 65 1.707 2.451 0.696, 93 1.707 2.230 0.448,
        48 1.718 3.101 0.700, 60 1.718 1.881 0.492, 79 2.288 2.892 0.405, 67 2.300 2.892 0.576, 95 2.323 2.521 0.319, 43 2.892 4.112 0.781,
        67 2.892 3.531 0.765, 79 2.892 3.519 0.540, 55 2.904 3.090 0.326, 95 2.973 3.357 0.312, 71 3.031 3.345 0.327, 65 3.507 4.089 0.720,
        55 3.531 3.705 0.336, 77 3.879 4.043 0.351, 64 4.089 4.763 0.729, 76 4.089 4.705 0.437, 92 4.089 4.612 0.428, 55 4.101 4.321 0.433,
        43 4.112 5.529 0.739, 62 4.693 5.332 0.584, 74 5.099 5.262 0.399, 48 5.308 6.505 0.698, 60 5.308 5.912 0.698, 76 5.587 5.784 0.316,
        72 5.900 6.459 0.450, 60 5.912 6.517 0.638, 76 5.983 6.355 0.349, 62 6.494 7.202 0.664, 74 6.494 7.074 0.362, 48 6.505 7.875 0.734,
        90 6.540 7.016 0.351, 64 7.098 7.701 0.761, 76 7.098 7.701 0.483, 92 7.098 7.376 0.302, 60 7.446 7.655 0.416, 55 7.701 7.922 0.462,
        64 7.701 8.631 0.753, 76 7.701 8.573 0.457, 92 7.701 8.504 0.392, 43 7.713 8.898 0.815, 62 8.597 8.898 0.647, 43 8.898 10.304 0.737,
        62 8.898 10.107 0.549, 74 8.898 10.049 0.432, 64 10.084 10.699 0.770, 60 10.095 10.699 0.414, 76 10.095 10.699 0.524, 92 10.095 10.432 0.317,
        48 10.107 11.303 0.792, 60 10.699 11.303 0.400, 64 10.699 11.291 0.779, 76 10.699 11.268 0.514, 92 10.699 11.164 0.314, 65 11.291 12.059 0.689,
        77 11.291 11.883 0.504, 48 11.303 12.697 0.702, 60 11.303 11.489 0.487, 93 11.303 11.849 0.452, 79 11.895 12.488 0.389, 67 11.907 12.500 0.581,
        95 11.931 12.105 0.319, 79 12.488 13.115 0.538, 43 12.500 13.115 0.762, 55 12.500 12.697 0.322, 67 12.500 13.127 0.762, 95 12.558 12.918 0.314,
        71 12.628 12.964 0.325, 65 13.092 13.707 0.711, 55 13.104 13.336 0.353, 43 13.115 13.719 0.821, 77 13.475 13.661 0.348, 55 13.707 13.906 0.436,
        64 13.707 14.371 0.726, 76 13.707 14.301 0.432, 92 13.707 14.220 0.430, 43 13.719 15.137 0.744, 62 14.289 14.928 0.579, 74 14.626 14.858 0.410,
        48 14.905 15.508 0.722, 60 14.905 15.508 0.703, 76 15.241 15.392 0.316, 72 15.497 16.078 0.428, 48 15.508 16.102 0.672, 60 15.508 16.113 0.655,
        76 15.624 15.939 0.346, 62 16.090 16.810 0.653, 74 16.090 16.671 0.373, 90 16.090 16.636 0.349, 48 16.102 17.309 0.779, 64 16.694 17.356 0.731,
        76 16.694 17.286 0.492, 92 16.694 17.170 0.310, 60 17.054 17.239 0.423, 62 17.298 18.251 0.668, 90 17.298 18.088 0.343, 48 17.309 18.204 0.806,
        74 17.657 18.146 0.367, 60 18.193 18.495 0.702, 48 18.204 18.495 0.629, 48 18.495 20.075 0.678, 60 18.495 20.052 0.608, 72 18.495 18.855 0.386,
        76 18.495 19.540 0.346, 72 19.005 19.586 0.392
        """)
}
