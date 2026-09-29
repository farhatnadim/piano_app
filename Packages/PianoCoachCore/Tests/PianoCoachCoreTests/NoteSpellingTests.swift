import XCTest
@testable import PianoCoachCore

final class NoteSpellingTests: XCTestCase {
    func testSharpAndFlatSpellings() {
        XCTAssertEqual(NoteSpelling.spell(60).nameWithOctave, "C4")
        XCTAssertEqual(NoteSpelling.spell(61).name, "C♯")
        XCTAssertEqual(NoteSpelling.spell(61, keyFifths: -2).name, "D♭")
        XCTAssertEqual(NoteSpelling.spell(70, keyFifths: -1).nameWithOctave, "B♭4")
        XCTAssertEqual(NoteSpelling.spell(59).nameWithOctave, "B3")
        XCTAssertEqual(NoteSpelling.spell(21).nameWithOctave, "A0")
    }

    func testStaffSteps() {
        XCTAssertEqual(NoteSpelling.spell(60).staffStep, 28)                         // middle C
        XCTAssertEqual(NoteSpelling.spell(64).staffStep, NoteSpelling.trebleBottomLine)  // E4
        XCTAssertEqual(NoteSpelling.spell(57).staffStep, NoteSpelling.bassTopLine)       // A3
        XCTAssertEqual(NoteSpelling.spell(61).staffStep, 28)                         // C♯4 sits on C's line
        XCTAssertEqual(NoteSpelling.spell(61, keyFifths: -3).staffStep, 29)          // D♭4 on D's space
    }

    func testBlackKeys() {
        XCTAssertEqual((60...71).filter(NoteSpelling.isBlackKey), [61, 63, 66, 68, 70])
    }
}

final class PieceCompatibilityTests: XCTestCase {
    /// Libraries saved before the game existed must still load.
    func testOldPieceJSONDecodesWithoutGameFields() throws {
        let json = #"{"id":"6F1C2F7E-8B7A-4C57-9E43-2D2D4E5A6B7C","title":"Old","videoID":"dQw4w9WgXcQ","createdAt":0,"hasLearnedTrack":false,"preferredMode":"waitForMe","resumeTime":0,"manualRate":1}"#
        let piece = try JSONDecoder().decode(Piece.self, from: Data(json.utf8))
        XCTAssertNil(piece.game)
        XCTAssertNil(piece.difficulty)
        var updated = piece
        updated.game = GameProgress(speed: 0.7)
        let round = try JSONDecoder().decode(Piece.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(round.game?.level, 7)
    }
}
