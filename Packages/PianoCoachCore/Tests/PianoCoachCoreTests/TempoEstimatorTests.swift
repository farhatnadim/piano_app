import XCTest
@testable import PianoCoachCore

final class TempoEstimatorTests: XCTestCase {
    /// A quarter-note melody with a bass note starting every measure of `beatsPerMeasure` beats.
    private func steadyTune(bpm: Double, beats: Int = 32, beatsPerMeasure: Int = 4, start: Double = 0.4) -> [TranscribedNote] {
        let spb = 60 / bpm
        var notes: [TranscribedNote] = []
        for k in 0..<beats {
            let t = start + Double(k) * spb
            notes.append(TranscribedNote(midi: [64, 65, 67, 62][k % 4], start: t, end: t + 0.9 * spb, amplitude: 0.6))
            if k % beatsPerMeasure == 0 {
                notes.append(TranscribedNote(midi: 48, start: t, end: t + Double(beatsPerMeasure) * spb * 0.9, amplitude: 0.5))
            }
        }
        return notes
    }

    func testSteadyTempos() throws {
        for bpm in [48.0, 66, 90, 120, 150, 184] {
            let t = try XCTUnwrap(TempoEstimator.estimate(steadyTune(bpm: bpm)), "\(bpm)")
            XCTAssertEqual(t.bpm / bpm, 1, accuracy: 0.005, "\(bpm)")
            XCTAssertEqual(t.secondsPerBeat, 60 / t.bpm)
            let phase = (0.4 - t.beatTime) / t.secondsPerBeat
            XCTAssertEqual(phase, phase.rounded(), accuracy: 0.02, "\(bpm): the beat falls on the notes")
            XCTAssertGreaterThan(t.confidence, 0.5, "\(bpm)")
        }
    }

    /// Clear pieces must not come out at half or double speed.
    func testNoOctaveErrorsOnClearPieces() throws {
        for piece in SyntheticSong.all {
            let t = try XCTUnwrap(TempoEstimator.estimate(piece.render(seed: 1, .none).notes))
            XCTAssertEqual(t.bpm / piece.bpm, 1, accuracy: 0.01, "\(piece.name) at \(piece.bpm)")
        }
    }

    /// An accompaniment in even eighth notes under a slow tune is genuinely ambiguous: the answer is the
    /// written tempo or its double, never something unrelated.
    func testEvenEighthAccompanimentGivesTheTempoOrItsDouble() throws {
        let rh = "E5:2 D5 | C5:1 D5 E5:2 | G5:2 F5 | E5:4 | E5:2 D5 | C5:1 D5 E5:2 | D5:2 B4 | C5:4"
        let lh = String(repeating: "C3:0.5 G3 E3 G3 C3 G3 E3 G3 | B2 G3 D3 G3 B2 G3 D3 G3 | ", count: 4)
        let piece = SyntheticSong(name: "Broken chords", notes: SyntheticSong.part(rh, hand: .right)
                                    + SyntheticSong.part(lh, hand: .left),
                                  bpm: 76, beatsPerMeasure: 4, tonic: 0, isMinor: false, fifths: 0)
        for seed: UInt64 in 1...3 {
            let bpm = try XCTUnwrap(TempoEstimator.estimate(piece.render(seed: seed).notes)).bpm
            XCTAssertTrue(abs(bpm / 76 - 1) < 0.02 || abs(bpm / 152 - 1) < 0.02, "\(bpm)")
        }
    }

    func testGradualTempoChangeGivesTheAverage() throws {
        var imperfections = SyntheticSong.Imperfections.none
        imperfections.drift = -0.05
        let (notes, truth) = SyntheticSong.bFlatTune().render(seed: 1, imperfections)
        let average = 60 * (truth.last!.beat - truth.first!.beat) / (truth.last!.start - truth.first!.start)
        let t = try XCTUnwrap(TempoEstimator.estimate(notes))
        XCTAssertEqual(t.bpm / average, 1, accuracy: 0.01)
    }

    func testBeatAtAGivenTempo() throws {
        let t = try XCTUnwrap(TempoEstimator.beat(steadyTune(bpm: 90, start: 1.23), bpm: 90))
        XCTAssertEqual(t.bpm, 90)
        let phase = (1.23 - t.beatTime) / t.secondsPerBeat
        XCTAssertEqual(phase, phase.rounded(), accuracy: 0.02)
        XCTAssertNil(TempoEstimator.beat([], bpm: 90))
        XCTAssertNil(TempoEstimator.beat(steadyTune(bpm: 90), bpm: 0))
    }

    func testTooFewOnsets() {
        XCTAssertNil(TempoEstimator.estimate([]))
        let chord = [60, 64, 67].map { TranscribedNote(midi: $0, start: 1, end: 2, amplitude: 0.5) }
        XCTAssertNil(TempoEstimator.estimate(chord))
        let three = (0..<3).map { TranscribedNote(midi: 60, start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.4, amplitude: 0.5) }
        XCTAssertNil(TempoEstimator.estimate(three))
    }

    func testMeterAndDownbeat() throws {
        for piece in [SyntheticSong.waltz(), .odeToJoy(), .cMajorScale(), .eMinorPiece()] {
            let (notes, truth) = piece.render(seed: 2)
            let tempo = try XCTUnwrap(TempoEstimator.estimate(notes))
            let meter = TempoEstimator.meter(notes, tempo: tempo)
            XCTAssertEqual(meter.timeSignature, TimeSignature(beats: piece.beatsPerMeasure, beatType: 4), piece.name)
            // The first downbeat of the piece is a whole number of measures from the estimated one.
            let firstDownbeat = try XCTUnwrap(truth.first { $0.beat == 0 }).start
            let measures = (firstDownbeat - meter.downbeatTime) / (tempo.secondsPerBeat * Double(piece.beatsPerMeasure))
            XCTAssertEqual(measures, measures.rounded(), accuracy: 0.05, piece.name)
        }
    }

    func testMeterDefaultsToFourFourWhenUnclear() {
        let tempo = TempoEstimate(bpm: 100, beatTime: 0, confidence: 1)
        XCTAssertEqual(TempoEstimator.meter([], tempo: tempo).timeSignature, .common)
        let short = Array(steadyTune(bpm: 100, beats: 9, beatsPerMeasure: 3).prefix(10))
        XCTAssertEqual(TempoEstimator.meter(short, tempo: tempo).timeSignature, .common)
    }
}
