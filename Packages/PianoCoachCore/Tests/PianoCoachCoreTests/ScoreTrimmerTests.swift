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

final class PickupTests: XCTestCase {
    /// A 3/8 tune starting with a pickup of two sixteenths (like Für Elise), then two full measures.
    private func tune() -> Score {
        let threeEight = TimeSignature(beats: 3, beatType: 8)
        let measures = [
            ScoreMeasure(index: 0, sourceIndex: 0, number: "0", startBeat: 0, lengthBeats: 0.5, timeSignature: threeEight),
            ScoreMeasure(index: 1, sourceIndex: 1, number: "1", startBeat: 0.5, lengthBeats: 1.5, timeSignature: threeEight),
            ScoreMeasure(index: 2, sourceIndex: 2, number: "2", startBeat: 2, lengthBeats: 1.5, timeSignature: threeEight),
        ]
        var notes = [(76, 0.0), (75, 0.25), (76, 0.5), (75, 0.75), (76, 1.0), (71, 1.25), (74, 1.5), (72, 1.75)].map {
            ScoreNote(midi: $0.0, beat: $0.1, durationBeats: 0.25, hand: .right, measureIndex: $0.1 < 0.5 ? 0 : 1)
        }
        notes.append(ScoreNote(midi: 69, beat: 2, durationBeats: 0.5, hand: .right, measureIndex: 2))
        notes.append(ScoreNote(midi: 45, beat: 2, durationBeats: 0.5, hand: .left, measureIndex: 2))
        notes.append(ScoreNote(midi: 52, beat: 2.5, durationBeats: 1, hand: .left, measureIndex: 2))
        return Score(title: "Tune", measures: measures, events: [], initialTempoBPM: 45, notes: notes)
    }

    func testThePickupSurvivesAMIDIFileAndReadsAsSheetMusic() throws {
        let parsed = try MIDIFileParser.parse(data: MIDIFileWriter.data(for: tune()))
        XCTAssertEqual(parsed.measures.map(\.startBeat), [0, 0.5, 2])
        let chart = try XCTUnwrap(NoteChart.from(score: parsed, title: "Tune"))
        let sheet = SheetMusic(chart: chart)
        let pickup = sheet.measures[0]
        XCTAssertEqual(pickup.lengthBeats, 0.5, accuracy: 1e-9)
        XCTAssertEqual(pickup.timeSignature, TimeSignature(beats: 3, beatType: 8), "written in the piece's 3/8, not 2/16")
        XCTAssertTrue(pickup.showsTimeSignature)
        XCTAssertFalse(sheet.measures[1].showsTimeSignature)
        // The pickup's two sixteenths are beamed; the silent bass staff gets an eighth rest, not a whole-measure rest.
        let treble = sheet.events.indices.filter { sheet.events[$0].clef == .treble && sheet.events[$0].measureIndex == 0 }
        XCTAssertEqual(treble.map { sheet.events[$0].value }, [.sixteenth, .sixteenth])
        XCTAssertNotNil(sheet.events[treble[0]].beam)
        XCTAssertEqual(sheet.events[treble[0]].beam, sheet.events[treble[1]].beam)
        let bass = sheet.events.filter { $0.clef == .bass && $0.measureIndex == 0 }
        XCTAssertEqual(bass.map(\.value), [.eighth])
        XCTAssertEqual(bass.map(\.isMeasureRest), [false])
        // A full measure of six sixteenths is one beamed group.
        let first = sheet.events.filter { $0.clef == .treble && $0.measureIndex == 1 }
        XCTAssertEqual(first.count, 6)
        XCTAssertEqual(Set(first.compactMap(\.beam)).count, 1)
    }

    func testEditingKeepsThePickupAndTrimmingStartsAfresh() throws {
        let score = tune()
        var notes = score.notes
        notes.removeLast()                                   // delete the last bass note
        let edited = try XCTUnwrap(score.rebuilt(withNotes: notes))
        XCTAssertEqual(edited.measures.map(\.startBeat), [0, 0.5, 2])
        XCTAssertEqual(edited.measures.map(\.lengthBeats), [0.5, 1.5, 1.5])
        // A note added past the end gets a new measure in the same time signature.
        notes.append(ScoreNote(midi: 57, beat: 3.5, durationBeats: 1.5, hand: .left, measureIndex: 0))
        let longer = try XCTUnwrap(score.rebuilt(withNotes: notes))
        XCTAssertEqual(longer.measures.map(\.startBeat), [0, 0.5, 2, 3.5])
        XCTAssertEqual(longer.notes.last?.measureIndex, 3)
        // Trimming lays the measures out again from its new start.
        let trimmed = try XCTUnwrap(ScoreTrimmer.trim(score, from: 0.5, to: 10))
        XCTAssertEqual(trimmed.measures.map(\.startBeat), [0, 1.5])
    }
}
