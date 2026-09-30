import XCTest
@testable import PianoCoachCore

final class ScoreTrimmerTests: XCTestCase {
    private func song() -> Score {
        // Two measures of 4/4: an "intro" of four quarter notes, then a chord and a long note.
        var notes: [ScoreNote] = []
        for i in 0..<4 { notes.append(ScoreNote(midi: 40 + i, beat: Double(i), durationBeats: 0.9, hand: .left, measureIndex: 0)) }
        notes.append(ScoreNote(midi: 60, beat: 4, durationBeats: 1, hand: .right, measureIndex: 1))
        notes.append(ScoreNote(midi: 64, beat: 4, durationBeats: 1, hand: .right, measureIndex: 1))
        notes.append(ScoreNote(midi: 67, beat: 5, durationBeats: 6, hand: .right, measureIndex: 1))
        let measures = (0..<3).map {
            ScoreMeasure(index: $0, sourceIndex: $0, number: "\($0 + 1)", startBeat: Double($0) * 4, lengthBeats: 4, timeSignature: .common)
        }
        return Score(title: "Song", measures: measures, events: [], initialTempoBPM: 90, notes: notes, keyFifths: 1)
    }

    func testCutsTheIntroAndMovesTheRestToTheStart() throws {
        let trimmed = try XCTUnwrap(ScoreTrimmer.trim(song(), from: 4, to: 100))
        XCTAssertEqual(trimmed.notes.map(\.midi), [60, 64, 67])
        XCTAssertEqual(trimmed.notes.map(\.beat), [0, 0, 1])
        XCTAssertEqual(trimmed.events.map(\.pitches), [[60, 64], [67]])
        XCTAssertEqual(trimmed.events.map(\.durationBeats), [1, 6])
        XCTAssertEqual(trimmed.measures.count, 2, "beats 0..<7 fit in two measures of 4")
        XCTAssertEqual(trimmed.notes.map(\.measureIndex), [0, 0, 0])
        XCTAssertEqual(trimmed.title, "Song")
        XCTAssertEqual(trimmed.initialTempoBPM, 90)
        XCTAssertEqual(trimmed.keyFifths, 1)
    }

    func testCutsTheEndAndShortensNotesReachingPastIt() throws {
        let trimmed = try XCTUnwrap(ScoreTrimmer.trim(song(), from: 0, to: 6))
        XCTAssertEqual(trimmed.notes.map(\.midi), [40, 41, 42, 43, 60, 64, 67])
        XCTAssertEqual(trimmed.notes.last?.durationBeats, 1, "the long note ends at the cut")
        XCTAssertEqual(trimmed.events.count, 6)
    }

    func testNothingLeftGivesNil() {
        XCTAssertNil(ScoreTrimmer.trim(song(), from: 20, to: 30))
        XCTAssertNil(ScoreTrimmer.trim(song(), from: 5, to: 5))
        XCTAssertNil(ScoreTrimmer.trim(song(), from: .nan, to: 5))
    }

    func testRoundTripsThroughAMIDIFile() throws {
        let trimmed = try XCTUnwrap(ScoreTrimmer.trim(song(), from: 4, to: 100))
        let parsed = try MIDIFileParser.parse(data: MIDIFileWriter.data(for: trimmed))
        XCTAssertEqual(parsed.notes.map(\.midi), [60, 64, 67])
        XCTAssertEqual(parsed.notes.map(\.beat), [0, 0, 1])
    }
}
