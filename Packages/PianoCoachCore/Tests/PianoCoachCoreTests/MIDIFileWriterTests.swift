import XCTest
@testable import PianoCoachCore

final class MIDIFileWriterTests: XCTestCase {
    func testVariableLengthQuantities() {
        XCTAssertEqual(MIDIFileWriter.variableLength(0), [0x00])
        XCTAssertEqual(MIDIFileWriter.variableLength(0x40), [0x40])
        XCTAssertEqual(MIDIFileWriter.variableLength(0x7F), [0x7F])
        XCTAssertEqual(MIDIFileWriter.variableLength(0x80), [0x81, 0x00])
        XCTAssertEqual(MIDIFileWriter.variableLength(480), [0x83, 0x60])
        XCTAssertEqual(MIDIFileWriter.variableLength(0x3FFF), [0xFF, 0x7F])
        XCTAssertEqual(MIDIFileWriter.variableLength(0x4000), [0x81, 0x80, 0x00])
        XCTAssertEqual(MIDIFileWriter.variableLength(0x0FFF_FFFF), [0xFF, 0xFF, 0xFF, 0x7F])
    }

    private func smallScore(title: String? = "Tune", notes: [ScoreNote], keyFifths: Int = -2, tempo: Double? = 100) -> Score {
        let measures = (0..<2).map {
            ScoreMeasure(index: $0, sourceIndex: $0, number: "\($0 + 1)", startBeat: Double($0 * 4), lengthBeats: 4,
                         timeSignature: .common)
        }
        return Score(title: title, measures: measures, events: [], initialTempoBPM: tempo, notes: notes, keyFifths: keyFifths)
    }

    private func occurrences(of bytes: [UInt8], in data: Data) -> Int {
        let all = [UInt8](data)
        guard all.count >= bytes.count else { return 0 }
        return (0...(all.count - bytes.count)).filter { Array(all[$0..<($0 + bytes.count)]) == bytes }.count
    }

    private func contains(_ data: Data, _ bytes: [UInt8]) -> Bool { occurrences(of: bytes, in: data) > 0 }

    func testFileLayout() {
        let score = smallScore(notes: [ScoreNote(midi: 70, beat: 0, durationBeats: 1, hand: .right, measureIndex: 0, velocity: 1),
                                       ScoreNote(midi: 46, beat: 0, durationBeats: 4, hand: .left, measureIndex: 0)])
        let data = MIDIFileWriter.data(for: score, isMinor: false)
        XCTAssertEqual(Array(data.prefix(14)), Array("MThd".utf8) + [0, 0, 0, 6, 0, 1, 0, 3, 0x01, 0xE0])
        XCTAssertEqual(occurrences(of: Array("MTrk".utf8), in: data), 3)
        XCTAssertTrue(contains(data, [0xFF, 0x03, 4] + Array("Tune".utf8)))
        XCTAssertTrue(contains(data, [0xFF, 0x03, 10] + Array("Right hand".utf8)))
        XCTAssertTrue(contains(data, [0xFF, 0x03, 9] + Array("Left hand".utf8)))
        XCTAssertTrue(contains(data, [0xFF, 0x58, 4, 4, 2, 24, 8]))                // 4/4
        XCTAssertTrue(contains(data, [0xFF, 0x59, 2, 0xFE, 0]))                    // two flats, major
        XCTAssertTrue(contains(data, [0xFF, 0x51, 3, 0x09, 0x27, 0xC0]))           // 600 000 µs = 100 BPM
        XCTAssertTrue(contains(data, [0xC0, 0, 0x00, 0x90, 70, 127]))              // piano, then B♭4 at full velocity
        XCTAssertTrue(contains(data, [0xC1, 0, 0x00, 0x91, 46, UInt8(MIDIFileWriter.defaultVelocity)]))
        XCTAssertTrue(contains(data, [0x83, 0x60, 0x80, 70, 64]))                  // released one beat later
        XCTAssertTrue(contains(MIDIFileWriter.data(for: score, isMinor: true), [0xFF, 0x59, 2, 0xFE, 1]))
    }

    /// Arranged songs survive a trip through a file: same notes, hands, timing, loudness, tempo, key and meter.
    func testRoundTripThroughTheParser() throws {
        for piece in [SyntheticSong.eMinorPiece(), .bFlatTune(), .waltz(), .crossingPiece()] {
            let song = try XCTUnwrap(SongArranger.arrange(piece.render(seed: 1).notes, title: piece.name))
            let parsed = try MIDIFileParser.parse(data: MIDIFileWriter.data(for: song.score, isMinor: song.isMinor))
            XCTAssertEqual(parsed.title, piece.name)
            XCTAssertEqual(parsed.initialTempoBPM ?? 0, song.tempoBPM, accuracy: 0.01, piece.name)
            XCTAssertEqual(parsed.keyFifths, song.keyFifths, piece.name)
            XCTAssertEqual(parsed.measures.first?.timeSignature, song.timeSignature, piece.name)
            XCTAssertEqual(parsed.measures.count, song.score.measures.count, piece.name)

            let original = try XCTUnwrap(NoteChart.from(score: song.score))
            let reread = try XCTUnwrap(NoteChart.from(score: parsed))
            XCTAssertEqual(reread.notes.count, original.notes.count, piece.name)
            XCTAssertEqual(reread.barLines, original.barLines, piece.name)
            XCTAssertEqual(reread.keyFifths, original.keyFifths, piece.name)
            let tick = 1.0 / 480
            for (a, b) in zip(original.notes, reread.notes) {
                XCTAssertEqual(b.midi, a.midi, piece.name)
                XCTAssertEqual(b.hand, a.hand, piece.name)
                XCTAssertEqual(b.time, a.time, accuracy: tick, piece.name)
                XCTAssertEqual(b.duration, a.duration, accuracy: 1.5 * tick, piece.name)
                XCTAssertEqual(b.velocity ?? -1, a.velocity ?? -2, accuracy: 0.5 / 127 + 1e-9, piece.name)
            }
        }
    }

    /// A right hand dipping below middle C stays the right hand, even with an empty left-hand track.
    func testHandsComeBackFromTrackNames() throws {
        let score = smallScore(notes: [ScoreNote(midi: 55, beat: 0, durationBeats: 1, hand: .right, measureIndex: 0),
                                       ScoreNote(midi: 53, beat: 1, durationBeats: 1, hand: .right, measureIndex: 0)])
        let parsed = try MIDIFileParser.parse(data: MIDIFileWriter.data(for: score))
        XCTAssertEqual(parsed.notes.map(\.hand), [.right, .right])
        let leftOnly = smallScore(notes: [ScoreNote(midi: 72, beat: 0, durationBeats: 1, hand: .left, measureIndex: 0)])
        XCTAssertEqual(try MIDIFileParser.parse(data: MIDIFileWriter.data(for: leftOnly)).notes.map(\.hand), [.left])
    }

    func testRepeatedKeysAndUntitledScores() throws {
        let score = smallScore(title: nil, notes: [
            ScoreNote(midi: 60, beat: 0, durationBeats: 1, hand: .right, measureIndex: 0),
            ScoreNote(midi: 60, beat: 1, durationBeats: 1, hand: .right, measureIndex: 0),
            ScoreNote(midi: 60, beat: 2, durationBeats: 0, hand: .right, measureIndex: 0),
        ], keyFifths: 9, tempo: nil)
        let parsed = try MIDIFileParser.parse(data: MIDIFileWriter.data(for: score))
        XCTAssertNil(parsed.title)
        XCTAssertNil(parsed.initialTempoBPM)
        XCTAssertEqual(parsed.keyFifths, 7)                     // clamped to seven sharps
        XCTAssertEqual(parsed.notes.map(\.beat), [0, 1, 2])
        XCTAssertEqual(parsed.notes.map(\.durationBeats), [1, 1, 1.0 / 480])
    }

    func testPickupMeasureKeepsItsLength() throws {
        let three = TimeSignature(beats: 3, beatType: 4)
        let measures = [
            ScoreMeasure(index: 0, sourceIndex: 0, number: "0", startBeat: 0, lengthBeats: 1, timeSignature: three),
            ScoreMeasure(index: 1, sourceIndex: 1, number: "1", startBeat: 1, lengthBeats: 3, timeSignature: three),
            ScoreMeasure(index: 2, sourceIndex: 2, number: "2", startBeat: 4, lengthBeats: 3, timeSignature: three),
        ]
        let notes = [0.0, 1, 4].map { ScoreNote(midi: 67, beat: $0, durationBeats: 1, hand: .right, measureIndex: 0) }
        let parsed = try MIDIFileParser.parse(data: MIDIFileWriter.data(for: Score(measures: measures, events: [], notes: notes)))
        XCTAssertEqual(parsed.measures.map(\.startBeat), [0, 1, 4])
        XCTAssertEqual(parsed.measures.map(\.lengthBeats), [1, 3, 3])
        XCTAssertEqual(parsed.measures.map(\.timeSignature), [TimeSignature(beats: 1, beatType: 4), three, three])
    }

    // MARK: - Parser additions

    func testHandFromTrackName() {
        XCTAssertEqual(MIDIFileParser.hand(forTrackName: "Right Hand"), .right)
        XCTAssertEqual(MIDIFileParser.hand(forTrackName: "Piano LH"), .left)
        XCTAssertEqual(MIDIFileParser.hand(forTrackName: "piano r.h."), .right)
        XCTAssertEqual(MIDIFileParser.hand(forTrackName: "Treble"), .right)
        XCTAssertEqual(MIDIFileParser.hand(forTrackName: "BASS"), .left)
        XCTAssertEqual(MIDIFileParser.hand(forTrackName: "Links/left"), .left)
        XCTAssertNil(MIDIFileParser.hand(forTrackName: "Rhythm"))
        XCTAssertNil(MIDIFileParser.hand(forTrackName: "Piano"))
        XCTAssertNil(MIDIFileParser.hand(forTrackName: "Left and right"))
    }

    func testHandsForNoteTracks() {
        XCTAssertEqual(MIDIFileParser.handsForNoteTracks(names: [nil, nil]), [.right, .left])
        XCTAssertEqual(MIDIFileParser.handsForNoteTracks(names: ["Piano", "Piano"]), [.right, .left])
        XCTAssertEqual(MIDIFileParser.handsForNoteTracks(names: ["Left hand", nil]), [.left, .right])
        XCTAssertEqual(MIDIFileParser.handsForNoteTracks(names: [nil, "RH"]), [.left, .right])
        XCTAssertEqual(MIDIFileParser.handsForNoteTracks(names: ["Bass", "Treble"]), [.left, .right])
        XCTAssertEqual(MIDIFileParser.handsForNoteTracks(names: [nil, "Left", nil]), [nil, .left, nil])
        XCTAssertEqual(MIDIFileParser.handsForNoteTracks(names: [nil]), [nil])
    }

    private func track(_ events: [UInt8]) -> [UInt8] {
        let body = events + [0x00, 0xFF, 0x2F, 0x00]
        let n = body.count
        return Array("MTrk".utf8) + [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + body
    }

    private func name(_ text: String) -> [UInt8] { [0x00, 0xFF, 0x03, UInt8(text.utf8.count)] + Array(text.utf8) }

    /// Named hand tracks win over the "first note track is the right hand" layout.
    func testNamedTracksOverrideTrackOrder() throws {
        var bytes = Array("MThd".utf8) + [0, 0, 0, 6, 0, 1, 0, 2, 0x01, 0xE0]
        bytes += track(name("Piano LH") + [0x00, 0x90, 64, 90, 0x83, 0x60, 0x80, 64, 0])
        bytes += track(name("Piano RH") + [0x00, 0x90, 52, 45, 0x83, 0x60, 0x80, 52, 0])
        let score = try MIDIFileParser.parse(data: Data(bytes))
        XCTAssertEqual(score.notes.map(\.midi), [52, 64])
        XCTAssertEqual(score.notes.map(\.hand), [.right, .left])
        XCTAssertEqual(score.notes[0].velocity ?? 0, 45.0 / 127, accuracy: 1e-12)
        XCTAssertEqual(score.notes[1].velocity ?? 0, 90.0 / 127, accuracy: 1e-12)
    }

    /// In a single-track file the track name is the song's title, not a hand.
    func testSingleTrackTitleIsNotAHand() throws {
        var bytes = Array("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0]
        bytes += track(name("Left Behind") + [0x00, 0xFF, 0x59, 0x02, 0xFD, 0x01,
                                              0x00, 0x90, 72, 100, 0x83, 0x60, 0x80, 72, 0])
        let score = try MIDIFileParser.parse(data: Data(bytes))
        XCTAssertEqual(score.title, "Left Behind")
        XCTAssertEqual(score.notes.map(\.hand), [.right])
        XCTAssertEqual(score.keyFifths, -3)
    }
}
