import XCTest
@testable import PianoCoachCore

final class KeyEstimatorTests: XCTestCase {
    func testSignaturesAndNames() {
        let cases: [(tonic: Int, minor: Bool, fifths: Int, name: String)] = [
            (0, false, 0, "C major"), (7, false, 1, "G major"), (2, false, 2, "D major"), (9, false, 3, "A major"),
            (4, false, 4, "E major"), (11, false, 5, "B major"), (6, false, -6, "G♭ major"), (1, false, -5, "D♭ major"),
            (8, false, -4, "A♭ major"), (3, false, -3, "E♭ major"), (10, false, -2, "B♭ major"), (5, false, -1, "F major"),
            (9, true, 0, "A minor"), (4, true, 1, "E minor"), (11, true, 2, "B minor"), (6, true, 3, "F♯ minor"),
            (1, true, 4, "C♯ minor"), (8, true, 5, "G♯ minor"), (3, true, -6, "E♭ minor"), (10, true, -5, "B♭ minor"),
            (5, true, -4, "F minor"), (0, true, -3, "C minor"), (7, true, -2, "G minor"), (2, true, -1, "D minor"),
        ]
        for c in cases {
            let fifths = KeyEstimator.fifths(tonicPitchClass: c.tonic, isMinor: c.minor)
            XCTAssertEqual(fifths, c.fifths, c.name)
            XCTAssertEqual(KeyEstimator.name(tonicPitchClass: c.tonic, isMinor: c.minor, fifths: fifths), c.name)
            let key = EstimatedKey(tonicPitchClass: c.tonic + 12, isMinor: c.minor)
            XCTAssertEqual(key.tonicPitchClass, c.tonic)
            XCTAssertEqual(key.name, c.name)
        }
    }

    /// Scales up and down in every key, ending on the tonic chord.
    func testScalesInEveryKey() {
        let major = [0, 2, 4, 5, 7, 9, 11, 12]
        let harmonicMinor = [0, 2, 3, 5, 7, 8, 11, 12]
        for tonic in 0..<12 {
            for minor in [false, true] {
                let steps = minor ? harmonicMinor : major
                var notes: [TranscribedNote] = []
                var t = 0.0
                for step in steps + steps.reversed().dropFirst() {
                    notes.append(TranscribedNote(midi: 60 + tonic + step, start: t, end: t + 0.4, amplitude: 0.6))
                    t += 0.45
                }
                for step in [0, minor ? 3 : 4, 7] {
                    notes.append(TranscribedNote(midi: 48 + tonic + step, start: t, end: t + 1.5, amplitude: 0.6))
                }
                let key = KeyEstimator.estimate(notes)
                XCTAssertEqual(key.tonicPitchClass, tonic, "\(tonic) \(minor)")
                XCTAssertEqual(key.isMinor, minor, "\(tonic) \(minor)")
                XCTAssertGreaterThan(key.confidence, 0)
            }
        }
    }

    func testPieces() {
        for piece in SyntheticSong.all {
            let key = KeyEstimator.estimate(piece.render(seed: 1).notes)
            XCTAssertEqual(key.tonicPitchClass, piece.tonic, piece.name)
            XCTAssertEqual(key.isMinor, piece.isMinor, piece.name)
            XCTAssertEqual(key.fifths, piece.fifths, piece.name)
        }
    }

    func testNothingToGoOn() {
        let key = KeyEstimator.estimate([])
        XCTAssertEqual(key.name, "C major")
        XCTAssertEqual(key.confidence, 0)
        XCTAssertEqual(KeyEstimator.estimate(pitchClassWeights: [1, 2]).confidence, 0)
    }

    func testHistogram() {
        // D major: D, F♯ and A strong, the rest of the scale present.
        var weights = [Double](repeating: 0, count: 12)
        for (pc, w) in [(2, 5.0), (4, 2), (6, 4), (7, 2), (9, 4), (11, 2), (1, 2)] { weights[pc] = w }
        let key = KeyEstimator.estimate(pitchClassWeights: weights)
        XCTAssertEqual(key.name, "D major")
        XCTAssertEqual(key.fifths, 2)
    }
}
