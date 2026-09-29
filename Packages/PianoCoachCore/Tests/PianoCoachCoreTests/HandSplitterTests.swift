import XCTest
@testable import PianoCoachCore

final class HandSplitterTests: XCTestCase {
    /// Share of the piece's own notes (not noise) given the hand they were written for.
    private func accuracy(_ piece: SyntheticSong, seed: UInt64 = 1) -> (splitter: Double, middleC: Double) {
        let (notes, truth) = piece.render(seed: seed, .none)
        let hands = HandSplitter.assignHands(notes)
        var right = 0, middleC = 0
        for (i, n) in notes.enumerated() {
            guard let t = truth.first(where: { $0.midi == n.midi && $0.start == n.start }) else { continue }
            if hands[i] == t.hand { right += 1 }
            if (n.midi >= 60 ? Hand.right : .left) == t.hand { middleC += 1 }
        }
        return (Double(right) / Double(truth.count), Double(middleC) / Double(truth.count))
    }

    func testMelodyAndBass() {
        for piece in [SyntheticSong.odeToJoy(), .gMajorTune(), .bFlatTune(), .eMinorPiece(), .cMajorScale()] {
            XCTAssertEqual(accuracy(piece).splitter, 1, piece.name)
        }
    }

    /// The tune walks down to G3 over a low bass, then the left hand's broken chords climb to G4: a split
    /// at middle C gets about a quarter of the notes wrong.
    func testHandsCrossingMiddleC() {
        let result = accuracy(.crossingPiece())
        XCTAssertGreaterThanOrEqual(result.splitter, 0.95)
        XCTAssertLessThan(result.middleC, 0.8)
    }

    func testMelodyOverOomPahPah() {
        XCTAssertGreaterThanOrEqual(accuracy(.waltz()).splitter, 0.95)
    }

    func testMelodyDipsBelowMiddleCOverALowBass() {
        let notes = [
            TranscribedNote(midi: 36, start: 0, end: 2, amplitude: 0.5), TranscribedNote(midi: 64, start: 0, end: 0.5, amplitude: 0.6),
            TranscribedNote(midi: 62, start: 0.5, end: 1, amplitude: 0.6), TranscribedNote(midi: 60, start: 1, end: 1.5, amplitude: 0.6),
            TranscribedNote(midi: 59, start: 1.5, end: 2, amplitude: 0.6), TranscribedNote(midi: 43, start: 2, end: 4, amplitude: 0.5),
            TranscribedNote(midi: 57, start: 2, end: 2.5, amplitude: 0.6), TranscribedNote(midi: 55, start: 2.5, end: 3, amplitude: 0.6),
            TranscribedNote(midi: 57, start: 3, end: 3.5, amplitude: 0.6), TranscribedNote(midi: 59, start: 3.5, end: 4, amplitude: 0.6),
        ]
        XCTAssertEqual(HandSplitter.assignHands(notes), [.left, .right, .right, .right, .right, .left, .right, .right, .right, .right])
    }

    func testBigChordIsSharedSensibly() {
        let pitches = [36, 40, 43, 48, 52, 55, 60, 64, 67, 72, 76, 79]
        let hands = HandSplitter.assignHands(pitches.map { TranscribedNote(midi: $0, start: 1, end: 2, amplitude: 0.6) })
        let left = zip(pitches, hands).filter { $0.1 == .left }.map(\.0)
        let right = zip(pitches, hands).filter { $0.1 == .right }.map(\.0)
        XCTAssertFalse(left.isEmpty)
        XCTAssertFalse(right.isEmpty)
        XCTAssertLessThan(left.max()!, right.min()!)
        XCTAssertLessThanOrEqual(max(left.count, right.count), 7)
    }

    func testOneHandAlone() {
        let thirds = (0..<8).flatMap { k -> [TranscribedNote] in
            let t = Double(k) * 0.4
            return [TranscribedNote(midi: 72 + k % 4, start: t, end: t + 0.35, amplitude: 0.6),
                    TranscribedNote(midi: 76 + k % 4, start: t, end: t + 0.35, amplitude: 0.6)]
        }
        XCTAssertEqual(Set(HandSplitter.assignHands(thirds)), [.right])
        let bass = [36, 43, 41, 38, 36, 31, 33, 36].enumerated().map {
            TranscribedNote(midi: $0.element, start: Double($0.offset) * 0.6, end: Double($0.offset) * 0.6 + 0.5, amplitude: 0.6)
        }
        XCTAssertEqual(Set(HandSplitter.assignHands(bass)), [.left])
    }

    func testHandsNeverCrossWithinAChord() {
        let notes = SyntheticSong.crossingPiece().render(seed: 3).notes
        let hands = HandSplitter.assignHands(notes)
        for group in notes.onsetGroups(window: HandSplitter.Options().chordWindow) {
            let left = group.filter { hands[$0] == .left }.map { notes[$0].midi }
            let right = group.filter { hands[$0] == .right }.map { notes[$0].midi }
            if let top = left.max(), let bottom = right.min() { XCTAssertLessThan(top, bottom) }
        }
    }

    func testKeepsInputOrder() {
        let notes = [TranscribedNote(midi: 72, start: 1, end: 2, amplitude: 0.6), TranscribedNote(midi: 36, start: 0, end: 2, amplitude: 0.6)]
        XCTAssertEqual(HandSplitter.assignHands(notes), [.right, .left])
        XCTAssertEqual(HandSplitter.assignHands([]), [])
    }
}
