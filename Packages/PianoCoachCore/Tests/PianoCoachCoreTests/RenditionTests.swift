import XCTest
@testable import PianoCoachCore

final class RenditionTests: XCTestCase {
    private func note(_ midi: Int, _ time: Double, _ duration: Double, _ hand: Hand, _ velocity: Double? = nil) -> ChartNote {
        ChartNote(id: 0, midi: midi, time: time, duration: duration, hand: hand, velocity: velocity)
    }

    /// Right hand: a chord, a held note under which a lower one starts, then a single note. Left hand: a
    /// chord, a very short note and a two-note chord.
    private var chart: NoteChart {
        NoteChart(title: "Song", notes: [
            note(64, 0, 1, .right, 0.5), note(67, 0, 1, .right, 0.6), note(72, 0, 2, .right, 0.9),
            note(69, 1, 1, .right, 0.7),
            note(71, 2, 2, .right, 0.8),
            note(48, 0, 2, .left, 0.4), note(55, 0, 2, .left, 0.3),
            note(43, 2, 0.2, .left, 0.5),
            note(45, 2.5, 1.5, .left, 0.45), note(52, 2.5, 1.5, .left, 0.35),
        ], beatsPerMinute: 96, barLines: [0, 4], source: .listening, keyFifths: 1, videoTimeOfBeatZero: 3.5)
    }

    private func summary(_ chart: NoteChart) -> [String] {
        chart.notes.map { "\($0.midi)\($0.hand == .left ? "L" : "R")@\($0.time)+\($0.duration)" }
    }

    func testFullIsUnchanged() {
        XCTAssertEqual(chart.rendition(.full), chart)
    }

    func testSimpleKeepsOneNotePerHand() {
        let simple = chart.rendition(.simple)
        // The top note C5 is cut off where A4 starts; the left hand's short G2 is gone.
        XCTAssertEqual(summary(simple), ["48L@0.0+2.0", "72R@0.0+1.0", "69R@1.0+1.0", "71R@2.0+2.0", "45L@2.5+1.5"])
        XCTAssertEqual(simple.notes.map(\.velocity), [0.4, 0.9, 0.7, 0.8, 0.45])
        XCTAssertEqual(simple.notes.map(\.id), Array(0..<5))
        assertKeepsDetails(simple)
    }

    func testMelodyIsTheRightHandsTopVoice() {
        let melody = chart.rendition(.melody)
        XCTAssertEqual(summary(melody), ["72R@0.0+1.0", "69R@1.0+1.0", "71R@2.0+2.0"])
        assertKeepsDetails(melody)
    }

    func testMelodyOfALeftHandOnlyChartUsesItsTopVoice() {
        let left = NoteChart(title: "Bass", notes: [note(40, 0, 1, .left), note(47, 0, 1, .left), note(45, 1, 1, .left)],
                             beatsPerMinute: 80, source: .score)
        XCTAssertEqual(summary(left.rendition(.melody)), ["47R@0.0+1.0", "45R@1.0+1.0"])
        XCTAssertTrue(NoteChart(title: "Empty", notes: [], beatsPerMinute: 80, source: .score).rendition(.simple).isEmpty)
    }

    func testRenditionOfAnArrangedSong() throws {
        let song = try XCTUnwrap(SongArranger.arrange(SyntheticSong.waltz().render(seed: 1).notes, title: "Waltz"))
        let full = try XCTUnwrap(song.chart)
        let simple = full.rendition(.simple)
        let melody = full.rendition(.melody)
        XCTAssertLessThan(melody.notes.count, simple.notes.count)
        XCTAssertLessThan(simple.notes.count, full.notes.count)
        for hand in Hand.allCases {
            let line = simple.notes.filter { $0.hand == hand }
            for (a, b) in zip(line, line.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.time + 1e-9) }
        }
    }

    func testNamesAndCoding() throws {
        XCTAssertEqual(Rendition.allCases, [.full, .simple, .melody])
        XCTAssertEqual(Rendition.allCases.map(\.displayName), ["Everything", "Easier", "Just the tune"])
        XCTAssertEqual(Set(Rendition.allCases.map(\.description)).count, 3)
        let data = try JSONEncoder().encode([Rendition.melody])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["melody"]"#)
        XCTAssertEqual(try JSONDecoder().decode([Rendition].self, from: data), [.melody])
    }

    private func assertKeepsDetails(_ reduced: NoteChart, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(reduced.title, "Song", file: file, line: line)
        XCTAssertEqual(reduced.beatsPerMinute, 96, file: file, line: line)
        XCTAssertEqual(reduced.barLines, [0, 4], file: file, line: line)
        XCTAssertEqual(reduced.source, .listening, file: file, line: line)
        XCTAssertEqual(reduced.keyFifths, 1, file: file, line: line)
        XCTAssertEqual(reduced.videoTimeOfBeatZero, 3.5, file: file, line: line)
    }
}

/// Velocity was added to saved notes later: older saved songs must still load.
final class VelocityCodingTests: XCTestCase {
    func testOldJSONWithoutVelocityStillDecodes() throws {
        let chartNote = try JSONDecoder().decode(ChartNote.self, from: Data(#"{"id":3,"midi":60,"time":1,"duration":0.5,"hand":"left"}"#.utf8))
        XCTAssertEqual(chartNote.midi, 60)
        XCTAssertEqual(chartNote.hand, .left)
        XCTAssertNil(chartNote.velocity)
        let scoreNote = try JSONDecoder().decode(ScoreNote.self, from: Data(
            #"{"midi":62,"beat":2,"durationBeats":1,"hand":"right","measureIndex":0}"#.utf8))
        XCTAssertNil(scoreNote.velocity)
        XCTAssertEqual(scoreNote.durationBeats, 1)
    }

    func testVelocityRoundTripsAndReachesTheChart() throws {
        let note = ScoreNote(midi: 64, beat: 0, durationBeats: 1, hand: .right, measureIndex: 0, velocity: 0.75)
        let decoded = try JSONDecoder().decode(ScoreNote.self, from: JSONEncoder().encode(note))
        XCTAssertEqual(decoded, note)
        let measure = ScoreMeasure(index: 0, sourceIndex: 0, number: "1", startBeat: 0, lengthBeats: 4, timeSignature: .common)
        let score = Score(measures: [measure], events: [], notes: [note,
            ScoreNote(midi: 48, beat: 0, durationBeats: 2, hand: .left, measureIndex: 0)])
        let chart = try XCTUnwrap(NoteChart.from(score: score))
        XCTAssertEqual(chart.notes.map(\.velocity), [nil, 0.75])
        let reloaded = try JSONDecoder().decode(NoteChart.self, from: JSONEncoder().encode(chart))
        XCTAssertEqual(reloaded, chart)
    }
}
