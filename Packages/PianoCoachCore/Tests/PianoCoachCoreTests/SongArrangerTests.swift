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
                                              amplitude: n.amplitude * rng.uniform(0.35, 0.6)))
            } else {
                output.append(n)
            }
            if n.midi + 12 <= 108, rng.chance(imperfections.ghostRate) {
                output.append(TranscribedNote(midi: n.midi + 12, start: n.start + rng.uniform(0, 0.01),
                                              end: n.start + n.duration * 0.5, amplitude: n.amplitude * rng.uniform(0.15, 0.3)))
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
    func testDiagnostics() throws {
        for piece in SyntheticSong.all {
            let (notes, truth) = piece.render(seed: 7)
            let song = try XCTUnwrap(SongArranger.arrange(notes, title: piece.name))
            let r = ArrangementReport(song, truth: truth, piece: piece)
            func f(_ x: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", x) }
            print("\(piece.name) @\(f(piece.bpm, 0)): bpm \(f(song.tempoBPM, 2)) (err \(f(r.tempoError * 100, 2))%) "
                + "\(song.keyName) \(song.timeSignature.beats)/\(song.timeSignature.beatType) "
                + "\(r.matched)/\(r.truthCount) hands \(f(r.handAccuracy * 100))% extra \(r.extra) "
                + "timing \(f(r.meanTimingError * 1000))/\(f(r.maxTimingError * 1000)) ms "
                + "downbeats \(f(r.downbeatAccuracy * 100, 0))%")
        }
    }
}

final class ScratchDebugTests: XCTestCase {
    func testAlberti() throws {
        let alberti = SyntheticSong(name: "Alberti", notes: SyntheticSong.part("""
            E5:2 D5 | C5:1 D5 E5:2 | G5:2 F5 | E5:4 | E5:2 D5 | C5:1 D5 E5:2 | D5:2 B4 | C5:4
            """, hand: .right) + SyntheticSong.part(String(repeating: "C3:0.5 G3 E3 G3 C3 G3 E3 G3 | B2 G3 D3 G3 B2 G3 D3 G3 | ", count: 3)
            + "C3 G3 E3 G3 C3 G3 E3 G3 | B2 G3 D3 G3 C3:2", hand: .left), bpm: 76, beatsPerMeasure: 4, tonic: 0, isMinor: false, fifths: 0)
        var line = ""
        for seed in 1...20 {
            let song = try XCTUnwrap(SongArranger.arrange(alberti.render(seed: UInt64(seed)).notes, title: "a"))
            line += String(format: " %.0f", song.tempoBPM)
        }
        print("alberti", line)
    }
}
