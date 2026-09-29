import XCTest
@testable import PianoCoachCore

final class NoteChartTests: XCTestCase {
    /// Synthesised two-hand playing through the real analyser: the transcriber should get most notes right.
    func testTranscriberFindsMostNotes() {
        let sr = 48_000.0
        let score = TestSupport.melodyScore()
        var notes: [SynthPiano.Note] = []
        for e in score.events {
            for p in e.pitches { notes.append(.init(midi: p, start: 0.5 + e.beat * 0.6, duration: 0.55, velocity: 0.55)) }
        }
        let extra: [[Int]] = [[48, 52, 55], [41, 57, 60], [36, 48], [43, 59, 62, 67], [72], [84], [33]]
        for (i, c) in extra.enumerated() {
            for p in c { notes.append(.init(midi: p, start: 21 + Double(i) * 0.8, duration: 0.7, velocity: 0.6)) }
        }
        let truth = score.events.map(\.pitches) + extra
        let audio = SynthPiano.render(notes, sampleRate: sr, length: 28, noiseLevel: 0.003)
        let analyzer = OnsetAnalyzer(sampleRate: sr)
        var onsets: [NoteOnset] = []
        var i = 0
        while i < audio.count {
            let end = min(audio.count, i + 1024)
            onsets += analyzer.process(Array(audio[i..<end]))
            i = end
        }
        onsets += analyzer.process([Float](repeating: 0, count: 20_000))
        XCTAssertEqual(onsets.count, truth.count)
        var hit = 0, extraNotes = 0, missed = 0
        for (o, t) in zip(onsets, truth) {
            let got = Set(NoteTranscriber.pitches(in: o.features)), want = Set(t)
            hit += got.intersection(want).count
            extraNotes += got.subtracting(want).count
            missed += want.subtracting(got).count
        }
        let precision = Double(hit) / Double(hit + extraNotes), recall = Double(hit) / Double(hit + missed)
        XCTAssertGreaterThan(precision, 0.85, "precision \(precision)")
        XCTAssertGreaterThan(recall, 0.85, "recall \(recall)")
    }

    func testTranscriberOnTemplates() {
        XCTAssertEqual(NoteTranscriber.pitches(in: .template(forPitches: [60])), [60])
        XCTAssertEqual(Set(NoteTranscriber.pitches(in: .template(forPitches: [60, 64, 67]))), [60, 64, 67])
        XCTAssertEqual(NoteTranscriber.pitches(in: .zero), [])
    }

    func testChartFromScoreKeepsHandsDurationsAndBars() throws {
        let xml = #"""
        <score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        <part id="P1">
        <measure number="1"><attributes><divisions>2</divisions><key><fifths>-1</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time><staves>2</staves></attributes>
          <note><pitch><step>C</step><octave>5</octave></pitch><duration>4</duration><type>half</type><staff>1</staff></note>
          <note><pitch><step>E</step><octave>5</octave></pitch><duration>2</duration><tie type="start"/><type>quarter</type><staff>1</staff></note>
          <note><pitch><step>E</step><octave>5</octave></pitch><duration>2</duration><tie type="stop"/><type>quarter</type><staff>1</staff></note>
          <backup><duration>8</duration></backup>
          <note><pitch><step>C</step><octave>3</octave></pitch><duration>8</duration><type>whole</type><staff>2</staff></note>
        </measure>
        <measure number="2">
          <note><pitch><step>G</step><octave>4</octave></pitch><duration>8</duration><type>whole</type><staff>1</staff></note>
          <backup><duration>8</duration></backup>
          <note><pitch><step>G</step><octave>2</octave></pitch><duration>8</duration><type>whole</type><staff>2</staff></note>
        </measure>
        </part></score-partwise>
        """#
        let score = try MusicXMLParser.parse(string: xml)
        XCTAssertEqual(score.keyFifths, -1)
        let chart = try XCTUnwrap(NoteChart.from(score: score, title: "Test"))
        XCTAssertEqual(chart.source, .score)
        XCTAssertEqual(chart.barLines, [0, 4])
        XCTAssertEqual(chart.notes.map(\.midi), [48, 72, 76, 43, 67])
        XCTAssertEqual(chart.notes.map(\.hand), [.left, .right, .right, .left, .right])
        // The tied E5 lasts two beats.
        XCTAssertEqual(chart.notes[2].time, 2, accuracy: 1e-9)
        XCTAssertEqual(chart.notes[2].duration, 2, accuracy: 1e-9)
        XCTAssertEqual(chart.notes[0].duration, 4, accuracy: 1e-9)
        XCTAssertEqual(chart.chords.count, 3)   // beats 0, 2 and 4
        XCTAssertEqual(chart.notes.map(\.id), Array(0..<5))
    }

    func testChartFromListeningShiftsToLeadIn() throws {
        let track = FollowTrack(origin: .learnedFromVideo, events: [
            TrackEvent(index: 0, videoTime: 12.0, features: .template(forPitches: [64])),
            TrackEvent(index: 1, videoTime: 12.5, features: .template(forPitches: [48, 67])),
            TrackEvent(index: 2, videoTime: 14.0, features: .template(forPitches: [60])),
        ])
        let chart = try XCTUnwrap(NoteChart.fromListening(track: track, title: "Heard", leadIn: 1))
        XCTAssertEqual(chart.source, .listening)
        XCTAssertEqual(chart.beatsPerMinute, 60)
        XCTAssertEqual(chart.videoTimeOfBeatZero ?? 0, 11, accuracy: 1e-9)
        XCTAssertEqual(chart.notes.map(\.midi), [64, 48, 67, 60])
        XCTAssertEqual(chart.notes[0].time, 1, accuracy: 1e-9)
        XCTAssertEqual(chart.notes[1].hand, .left)
        XCTAssertEqual(chart.notes[0].duration, 0.5, accuracy: 1e-9)
    }

    func testMIDIHandsFromTwoTracks() throws {
        // Format 1: tempo track, right-hand track (C5), left-hand track (C3).
        func track(_ events: [UInt8]) -> [UInt8] {
            let body = events + [0x00, 0xFF, 0x2F, 0x00]
            let n = body.count
            return Array("MTrk".utf8) + [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + body
        }
        var bytes = Array("MThd".utf8) + [0, 0, 0, 6, 0, 1, 0, 3, 0x01, 0xE0]
        bytes += track([0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20])
        bytes += track([0x00, 0x90, 72, 80, 0x83, 0x60, 0x80, 72, 0])
        bytes += track([0x00, 0x90, 48, 80, 0x87, 0x40, 0x80, 48, 0])
        let score = try MIDIFileParser.parse(data: Data(bytes))
        XCTAssertEqual(score.notes.map(\.midi), [48, 72])
        XCTAssertEqual(score.notes.map(\.hand), [.left, .right])
        XCTAssertEqual(score.notes[0].durationBeats, 2, accuracy: 1e-9)
        XCTAssertEqual(score.notes[1].durationBeats, 1, accuracy: 1e-9)
    }
}
