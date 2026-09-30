import XCTest
@testable import PianoCoachCore

/// Malformed or extreme input that must not crash, hang or produce non-finite values.
final class RobustnessTests: XCTestCase {
    // MARK: - MusicXML

    private func partwise(_ measure: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
          <part id="P1"><measure number="1">
            <attributes><divisions>1</divisions></attributes>
            \(measure)
            <note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration></note>
          </measure></part>
        </score-partwise>
        """
    }

    private func pitchedNote(octave: String = "4", alter: String? = nil, duration: String = "1",
                             staff: String? = nil) -> String {
        var s = "<note><pitch><step>D</step>"
        if let alter { s += "<alter>\(alter)</alter>" }
        s += "<octave>\(octave)</octave></pitch><duration>\(duration)</duration>"
        if let staff { s += "<staff>\(staff)</staff>" }
        return s + "</note>"
    }

    func testMusicXMLHugeOctaveIsSkipped() throws {
        let score = try MusicXMLParser.parse(string: partwise(pitchedNote(octave: "999999999999999999")))
        XCTAssertEqual(score.notes.map(\.midi), [60])
    }

    func testMusicXMLNonFiniteOrHugeAlterIsSkipped() throws {
        for alter in ["nan", "inf", "1e300", "-1e300"] {
            let score = try MusicXMLParser.parse(string: partwise(pitchedNote(alter: alter)))
            XCTAssertEqual(score.notes.map(\.midi), [60], alter)
        }
    }

    func testMusicXMLHugeStaffNumber() throws {
        let score = try MusicXMLParser.parse(string: partwise(pitchedNote(staff: "9223372036854775807")))
        XCTAssertEqual(score.notes.map(\.midi), [62, 60])
    }

    func testMusicXMLNonFiniteDurationsStayFinite() throws {
        for duration in ["inf", "nan", "1e400"] {
            let xml = partwise(pitchedNote(duration: duration) + "<backup><duration>\(duration)</duration></backup>"
                               + "<forward><duration>\(duration)</duration></forward>")
            let score = try MusicXMLParser.parse(string: xml)
            XCTAssertTrue(score.measures.allSatisfy { $0.startBeat.isFinite && $0.lengthBeats.isFinite }, duration)
            XCTAssertTrue(score.notes.allSatisfy { $0.beat.isFinite && $0.durationBeats.isFinite }, duration)
            XCTAssertTrue(score.events.allSatisfy { $0.beat.isFinite && $0.durationBeats.isFinite }, duration)
            _ = MIDIFileWriter.data(for: score)
        }
    }

    func testMusicXMLOverflowingTimeSignatureIsIgnored() throws {
        for (beats, type) in [("9223372036854775807+1", "4"), ("3", "9223372036854775807"), ("4", "0")] {
            let xml = partwise("<attributes><time><beats>\(beats)</beats><beat-type>\(type)</beat-type></time></attributes>")
            let score = try MusicXMLParser.parse(string: xml)
            XCTAssertTrue(score.measures.allSatisfy { $0.lengthBeats.isFinite && $0.lengthBeats > 0 })
        }
        // Composite signatures whose common beat type would overflow.
        let composite = "<attributes><time><beats>3</beats><beat-type>4611686018427387904</beat-type>"
            + "<beats>2</beats><beat-type>3</beat-type></time></attributes>"
        _ = try MusicXMLParser.parse(string: partwise(composite))
    }

    func testMusicXMLHugeMetronomeTempoIsIgnored() throws {
        let digits = String(repeating: "9", count: 400)
        let xml = partwise("<direction><direction-type><metronome><beat-unit>quarter</beat-unit>"
                           + "<per-minute>\(digits)</per-minute></metronome></direction-type></direction>")
        let score = try MusicXMLParser.parse(string: xml)
        XCTAssertNil(score.initialTempoBPM)
    }

    // MARK: - MIDI

    private func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    private func midiFile(ppq: UInt8, track: [UInt8]) -> Data {
        Data(Array("MThd".utf8) + be32(6) + [0, 0, 0, 1, 0, ppq] + Array("MTrk".utf8) + be32(track.count) + track)
    }

    /// Maximal delta times with one tick per quarter note would lay out hundreds of millions of measures.
    func testMIDIWithAbsurdLengthIsRejectedQuickly() {
        var track: [UInt8] = [0x00, 0x90, 0x3C, 0x64]
        for _ in 0..<8 { track += [0xFF, 0xFF, 0xFF, 0x7F, 0x90, 0x3C, 0x64] }
        track += [0x00, 0xFF, 0x2F, 0x00]
        XCTAssertThrowsError(try MIDIFileParser.parse(data: midiFile(ppq: 1, track: track)))
    }

    func testMIDITinyTimeSignatureDoesNotExplode() throws {
        // 1/32768 time signature, then a note ten quarter notes later.
        let track: [UInt8] = [0x00, 0xFF, 0x58, 0x04, 0x01, 0x0F, 0x18, 0x08,
                              0x00, 0x90, 0x3C, 0x64, 0x83, 0x60, 0x80, 0x3C, 0x40,
                              0x00, 0xFF, 0x2F, 0x00]
        let score = try MIDIFileParser.parse(data: midiFile(ppq: 0x60, track: track))
        XCTAssertLessThan(score.measures.count, 100)
    }

    // MARK: - Synth, charts, tempo

    func testSynthPianoToleratesNegativeStartAndDuration() {
        let notes = [SynthPiano.Note(midi: 60, start: -0.5, duration: 1),
                     SynthPiano.Note(midi: 64, start: 0.1, duration: -1),
                     SynthPiano.Note(midi: 67, start: .nan, duration: 1)]
        let out = SynthPiano.render(notes, sampleRate: 8000, length: 1)
        XCTAssertEqual(out.count, 8000)
        XCTAssertTrue(out.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(out.prefix(400).map(abs).max() ?? 0, 0, "the note that started early still sounds")
    }

    func testNoteChartRejectsNonFiniteTempo() {
        let chart = NoteChart(title: "x", notes: [ChartNote(id: 0, midi: 60, time: 0, duration: 1, hand: .right)],
                              beatsPerMinute: .infinity, source: .score)
        XCTAssertEqual(chart.beatsPerMinute, 60)
        let engine = GameEngine(chart: chart)
        XCTAssertTrue(engine.position.isFinite)
    }

    func testTempoBeatRejectsNonFiniteBPM() {
        let notes = (0..<8).map { TranscribedNote(midi: 60, start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.4, amplitude: 0.5) }
        XCTAssertNil(TempoEstimator.beat(notes, bpm: .infinity))
        var options = SongArranger.Options()
        options.tempoBPM = .infinity
        XCTAssertNotNil(SongArranger.arrange(notes, title: "x", options: options))
    }

    func testYouTubeStartTimeMustBeFinite() {
        let huge = String(repeating: "9", count: 400)
        XCTAssertNil(YouTubeLink.parseTime(huge))
        XCTAssertNil(YouTubeLink.parseTime(huge + "s"))
        XCTAssertNil(YouTubeLink.parseTime("1:" + huge))
    }
}
