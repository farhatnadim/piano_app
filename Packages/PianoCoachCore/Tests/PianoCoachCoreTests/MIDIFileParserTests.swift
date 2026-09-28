import XCTest
@testable import PianoCoachCore

final class MIDIFileParserTests: XCTestCase {
    // MARK: - Builders

    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    /// "MThd" header followed by one "MTrk" chunk per track body.
    private func midiFile(format: Int, division: [UInt8] = [0x01, 0xE0], tracks: [[UInt8]]) -> Data {
        var bytes = Array("MThd".utf8) + be32(6) + be16(format) + be16(tracks.count) + division
        for body in tracks { bytes += Array("MTrk".utf8) + be32(body.count) + body }
        return Data(bytes)
    }

    private let endOfTrack: [UInt8] = [0x00, 0xFF, 0x2F, 0x00]

    // MARK: - Format 0

    /// ppq 480, 3/4, 120 BPM, running status, velocity-0 note-offs, a chord, a near-simultaneous
    /// note, sysex and drum notes (channel 10) that must be ignored.
    private var format0: Data {
        let track: [UInt8] = [
            0x00, 0xFF, 0x03, 0x06, 0x4D, 0x69, 0x6E, 0x75, 0x65, 0x74,  // track name "Minuet"
            0x00, 0xFF, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08,              // time signature 3/4
            0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,                    // tempo 500000 us/quarter
            0x00, 0xC0, 0x00,                                            // program change (one data byte)
            0x00, 0x99, 0x24, 0x64,                                      // drum note on: ignored
            0x00, 0x90, 0x3C, 0x64,                                      // @0    C4 on
            0x00, 0x40, 0x50,                                            // @0    E4 on (running status)
            0x00, 0x43, 0x50,                                            // @0    G4 on (running status)
            0x83, 0x60, 0x3C, 0x00,                                      // @480  C4 off (velocity 0)
            0x00, 0x40, 0x00,                                            // @480  E4 off
            0x00, 0x43, 0x00,                                            // @480  G4 off
            0x00, 0x3E, 0x64,                                            // @480  D4 on
            0x83, 0x60, 0x80, 0x3E, 0x40,                                // @960  D4 off (0x80)
            0x00, 0x90, 0x40, 0x64,                                      // @960  E4 on
            0x05, 0x43, 0x64,                                            // @965  G4 on: same event as E4
            0x00, 0xF0, 0x05, 0x7E, 0x7F, 0x09, 0x01, 0xF7,              // sysex: skipped
            0x83, 0x5B, 0x90, 0x40, 0x00,                                // @1440 E4 off
            0x00, 0x43, 0x00,                                            // @1440 G4 off
            0x00, 0x89, 0x24, 0x40,                                      // drum note off: ignored
            0x00, 0x90, 0x41, 0x64,                                      // @1440 F4 on
            0x8F, 0x00, 0x41, 0x00,                                      // @3360 F4 off (delta 1920)
        ] + endOfTrack
        return midiFile(format: 0, tracks: [track])
    }

    func testFormat0() throws {
        let score = try MIDIFileParser.parse(data: format0)
        XCTAssertEqual(score.title, "Minuet")
        XCTAssertNil(score.composer)
        XCTAssertEqual(score.initialTempoBPM, 120)

        XCTAssertEqual(score.events.map(\.beat), [0, 1, 2, 3])
        XCTAssertEqual(score.events.map(\.pitches), [[60, 64, 67], [62], [64, 67], [65]])
        XCTAssertEqual(score.events.map(\.index), [0, 1, 2, 3])
        // The last event lasts as long as its longest note (F4: 1920 ticks = 4 beats).
        XCTAssertEqual(score.events.map(\.durationBeats), [1, 1, 1, 4])
        XCTAssertEqual(score.events.map(\.measureIndex), [0, 0, 0, 1])
        XCTAssertEqual(score.events.map(\.sourceMeasureIndex), [0, 0, 0, 1])
        XCTAssertEqual(score.events.map(\.beatInMeasure), [0, 1, 2, 0])

        // 3/4 measures covering the end of the last note (beat 7).
        let threeFour = TimeSignature(beats: 3, beatType: 4)
        XCTAssertEqual(score.measures.map(\.number), ["1", "2", "3"])
        XCTAssertEqual(score.measures.map(\.index), [0, 1, 2])
        XCTAssertEqual(score.measures.map(\.sourceIndex), [0, 1, 2])
        XCTAssertEqual(score.measures.map(\.startBeat), [0, 3, 6])
        XCTAssertEqual(score.measures.map(\.lengthBeats), [3, 3, 3])
        XCTAssertEqual(score.measures.map(\.timeSignature), [threeFour, threeFour, threeFour])
        XCTAssertEqual(score.measure(numbered: 2)?.startBeat, 3)
    }

    // MARK: - Format 1

    /// ppq 96: a conductor track (title, 100 BPM, 4/4 then 3/4 at beat 4, a later tempo change),
    /// right hand (channel 1), left hand (channel 2) and a drum track (channel 10).
    private var format1: Data {
        let conductor: [UInt8] = [
            0x00, 0xFF, 0x03, 0x0A] + Array("Song Title".utf8) + [
            0x00, 0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08,              // @0   4/4
            0x00, 0xFF, 0x51, 0x03, 0x09, 0x27, 0xC0,                    // @0   600000 us -> 100 BPM
            0x83, 0x00, 0xFF, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08,        // @384 3/4
            0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,                    // @384 120 BPM (not the initial tempo)
        ] + endOfTrack
        let rightHand: [UInt8] = [
            0x00, 0xFF, 0x03, 0x0A] + Array("Right Hand".utf8) + [
            0x00, 0x90, 0x48, 0x64,                                      // @0   C5 on
            0x60, 0x48, 0x00,                                            // @96  C5 off (running, velocity 0)
            0x00, 0x4A, 0x64,                                            // @96  D5 on
            0x60, 0x4A, 0x00,                                            // @192 D5 off
            0x00, 0x4C, 0x64,                                            // @192 E5 on
            0x81, 0x40, 0x80, 0x4C, 0x00,                                // @384 E5 off (0x80)
            0x00, 0x90, 0x4F, 0x64,                                      // @384 G5 on
            0x82, 0x20, 0x4F, 0x00,                                      // @672 G5 off
        ] + endOfTrack
        let leftHand: [UInt8] = [
            0x00, 0x91, 0x30, 0x64,                                      // @0   C3 on (channel 2)
            0x83, 0x00, 0x30, 0x00,                                      // @384 C3 off
            0x02, 0x37, 0x64,                                            // @386 G3 on: within ppq/24 of G5
            0x82, 0x1E, 0x37, 0x00,                                      // @672 G3 off
        ] + endOfTrack
        let drums: [UInt8] = [
            0x00, 0x99, 0x24, 0x64,
            0x60, 0x89, 0x24, 0x00,
            0x00, 0x99, 0x26, 0x64,
            0x87, 0x00, 0x26, 0x00,                                      // @992: past the last pitched note
        ] + endOfTrack
        return midiFile(format: 1, division: [0x00, 0x60], tracks: [conductor, rightHand, leftHand, drums])
    }

    func testFormat1WithTempoTrack() throws {
        let score = try MIDIFileParser.parse(data: format1)
        XCTAssertEqual(score.title, "Song Title")
        XCTAssertEqual(score.initialTempoBPM, 100)

        XCTAssertEqual(score.events.map(\.beat), [0, 1, 2, 4])
        XCTAssertEqual(score.events.map(\.pitches), [[48, 72], [74], [76], [55, 79]])
        XCTAssertEqual(score.events.map(\.durationBeats), [1, 1, 2, 3])
        XCTAssertEqual(score.events.map(\.measureIndex), [0, 0, 0, 1])
        XCTAssertEqual(score.events.map(\.beatInMeasure), [0, 1, 2, 0])

        // Drum notes do not extend the piece: two measures, 4/4 then 3/4, ending at beat 7.
        XCTAssertEqual(score.measures.map(\.number), ["1", "2"])
        XCTAssertEqual(score.measures.map(\.startBeat), [0, 4])
        XCTAssertEqual(score.measures.map(\.lengthBeats), [4, 3])
        XCTAssertEqual(score.measures.map(\.timeSignature), [.common, TimeSignature(beats: 3, beatType: 4)])
        XCTAssertEqual(score.totalBeats, 7)
    }

    func testGroupingWindowIsMeasuredFromTheGroupsFirstNote() throws {
        // ppq 96 -> window of 4 ticks. Notes at 0, 3 and 6: {0, 3} group at tick 0; 6 starts a new event.
        let track: [UInt8] = [
            0x00, 0x90, 0x3C, 0x64,
            0x03, 0x3E, 0x64,
            0x03, 0x40, 0x64,
            0x60, 0x3C, 0x00, 0x00, 0x3E, 0x00, 0x00, 0x40, 0x00,  // all off at 102
        ] + endOfTrack
        let score = try MIDIFileParser.parse(data: midiFile(format: 0, division: [0x00, 0x60], tracks: [track]))
        XCTAssertEqual(score.events.map(\.pitches), [[60, 62], [64]])
        XCTAssertEqual(score.events[0].beat, 0)
        XCTAssertEqual(score.events[1].beat, 6.0 / 96, accuracy: 1e-12)
        XCTAssertEqual(score.events[1].durationBeats, 1, accuracy: 1e-12)  // 96 ticks
        XCTAssertNil(score.title)
        XCTAssertNil(score.initialTempoBPM)
        XCTAssertEqual(score.measures.count, 1)
        XCTAssertEqual(score.measures[0].timeSignature, .common)  // default without a time-signature event
    }

    func testRepeatedNoteOnsAndNotesNeverSwitchedOff() throws {
        let track: [UInt8] = [
            0x00, 0x90, 0x3C, 0x64,        // @0   C4 on
            0x60, 0x3C, 0x64,              // @96  C4 on again (still sounding)
            0x60, 0x3C, 0x00,              // @192 first C4 off
            0x60, 0x3C, 0x00,              // @288 second C4 off
            0x00, 0x43, 0x64,              // @288 G4 on, never switched off
            0x83, 0x00, 0xFF, 0x2F, 0x00,  // end of track @672
        ]
        let score = try MIDIFileParser.parse(data: midiFile(format: 0, division: [0x00, 0x60], tracks: [track]))
        XCTAssertEqual(score.events.map(\.beat), [0, 1, 3])
        XCTAssertEqual(score.events.map(\.pitches), [[60], [60], [67]])
        XCTAssertEqual(score.events.last?.durationBeats, 4)  // held until the end of the track
        XCTAssertEqual(score.measures.map(\.startBeat), [0, 4])
    }

    // MARK: - Measures

    func testTimeSignatureChangeInsideAMeasureStartsANewMeasure() {
        let measures = MIDIFileParser.buildMeasures(
            signatures: [(0, .common), (192, TimeSignature(beats: 3, beatType: 4))],
            ppq: 96, lastOnset: 500, endTick: 600)
        XCTAssertEqual(measures.map(\.startBeat), [0, 2, 5])
        XCTAssertEqual(measures.map(\.lengthBeats), [2, 3, 3])
        XCTAssertEqual(measures.map(\.timeSignature.beats), [4, 3, 3])
        XCTAssertEqual(measures.map(\.number), ["1", "2", "3"])
    }

    func testMeasuresCoverANoteStartingOnTheLastBarline() {
        // A zero-length note exactly on beat 4 still gets a measure.
        let measures = MIDIFileParser.buildMeasures(signatures: [], ppq: 480, lastOnset: 1920, endTick: 1920)
        XCTAssertEqual(measures.map(\.startBeat), [0, 4])
    }

    // MARK: - Containers and errors

    func testRIFFWrappedMIDI() throws {
        let smf = [UInt8](format0)
        var riff = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("RMID".utf8)
        riff += Array("data".utf8) + [UInt8(smf.count & 0xFF), UInt8(smf.count >> 8), 0, 0] + smf
        let score = try MIDIFileParser.parse(data: Data(riff))
        XCTAssertEqual(score.title, "Minuet")
        XCTAssertEqual(score.events.count, 4)
    }

    func testIgnoresUnknownChunks() throws {
        var bytes = [UInt8](format0)
        bytes.insert(contentsOf: Array("XFIH".utf8) + be32(3) + [1, 2, 3], at: 14)
        XCTAssertEqual(try MIDIFileParser.parse(data: Data(bytes)).events.count, 4)
    }

    func testRejectsFormat2() {
        let data = midiFile(format: 2, tracks: [[0x00, 0x90, 0x3C, 0x64] + endOfTrack])
        XCTAssertThrowsError(try MIDIFileParser.parse(data: data)) {
            XCTAssertEqual($0 as? MIDIFileError, .unsupportedFormat(2))
        }
    }

    func testRejectsSMPTETiming() {
        let data = midiFile(format: 0, division: [0xE7, 0x28], tracks: [[0x00, 0x90, 0x3C, 0x64] + endOfTrack])
        XCTAssertThrowsError(try MIDIFileParser.parse(data: data)) {
            XCTAssertEqual($0 as? MIDIFileError, .smpteTimeDivisionNotSupported)
        }
    }

    func testRejectsNonMIDIData() {
        for bytes in [Data(), Data("hello, world".utf8), Data("RIFF\u{0}\u{0}\u{0}\u{0}RMIDjunk".utf8)] {
            XCTAssertThrowsError(try MIDIFileParser.parse(data: bytes)) {
                XCTAssertEqual($0 as? MIDIFileError, .notAMIDIFile)
            }
        }
    }

    func testDrumsOnlyHasNoNotes() {
        let data = midiFile(format: 0, tracks: [[0x00, 0x99, 0x24, 0x64, 0x60, 0x24, 0x00] + endOfTrack])
        XCTAssertThrowsError(try MIDIFileParser.parse(data: data)) { XCTAssertEqual($0 as? MIDIFileError, .noNotes) }
    }

    func testRejectsDataByteWithoutRunningStatus() {
        let data = midiFile(format: 0, tracks: [[0x00, 0x3C, 0x64] + endOfTrack])
        XCTAssertThrowsError(try MIDIFileParser.parse(data: data)) { error in
            guard case MIDIFileError.invalidData = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testRejectsTruncatedEvent() {
        let data = midiFile(format: 0, tracks: [[0x00, 0x90, 0x3C]])
        XCTAssertThrowsError(try MIDIFileParser.parse(data: data)) { XCTAssertEqual($0 as? MIDIFileError, .truncated) }
        let longVLQ = midiFile(format: 0, tracks: [[0x81, 0x81, 0x81, 0x81, 0x01, 0x90, 0x3C, 0x64]])
        XCTAssertThrowsError(try MIDIFileParser.parse(data: longVLQ)) { error in
            guard case MIDIFileError.invalidData = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testToleratesTrackLengthPastEndOfFile() throws {
        var bytes = [UInt8](midiFile(format: 0, tracks: [[0x00, 0x90, 0x3C, 0x64, 0x60, 0x3C, 0x00]]))
        bytes[18...21] = [0x00, 0x00, 0x10, 0x00]  // claims 4096 bytes, no end-of-track event
        let score = try MIDIFileParser.parse(data: Data(bytes))
        XCTAssertEqual(score.events.map(\.pitches), [[60]])
        XCTAssertEqual(score.events[0].durationBeats, 96.0 / 480)
    }
}
