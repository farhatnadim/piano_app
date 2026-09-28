import XCTest
@testable import PianoCoachCore

/// The parser's event positions must line up with OpenSheetMusicDisplay's cursor steps, which the
/// app uses to place the sheet-music cursor. The expected steps were recorded from OSMD 2.1.3
/// (WebAssets/sheet.html) rendering this same file: measures 1-2 repeated, then 3-4.
final class SheetCursorCompatibilityTests: XCTestCase {
    static let xml = #"""
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
<score-partwise version="4.0"><work><work-title>Test Piece</work-title></work><identification><creator type="composer">Tester</creator></identification><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list><part id="P1"><measure number="1"><attributes><divisions>1</divisions><key><fifths>0</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time><staves>2</staves><clef number="1"><sign>G</sign><line>2</line></clef><clef number="2"><sign>F</sign><line>4</line></clef></attributes><barline location="left"><repeat direction="forward"/></barline><note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type><staff>1</staff></note><note><pitch><step>D</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type><staff>1</staff></note><note><pitch><step>E</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type><staff>1</staff></note><note><pitch><step>F</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type><staff>1</staff></note><backup><duration>4</duration></backup><note><pitch><step>C</step><octave>3</octave></pitch><duration>4</duration><voice>5</voice><type>whole</type><staff>2</staff></note><note><chord/><pitch><step>G</step><octave>3</octave></pitch><duration>4</duration><voice>5</voice><type>whole</type><staff>2</staff></note></measure><measure number="2"><note><pitch><step>G</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type><staff>1</staff></note><note><pitch><step>G</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type><staff>1</staff></note><note><pitch><step>A</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type><staff>1</staff></note><note><pitch><step>B</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type><staff>1</staff></note><backup><duration>4</duration></backup><note><pitch><step>C</step><octave>3</octave></pitch><duration>4</duration><voice>5</voice><type>whole</type><staff>2</staff></note><note><chord/><pitch><step>G</step><octave>3</octave></pitch><duration>4</duration><voice>5</voice><type>whole</type><staff>2</staff></note><barline location="right"><bar-style>light-heavy</bar-style><repeat direction="backward"/></barline></measure><measure number="3"><note><pitch><step>C</step><octave>5</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type><staff>1</staff></note><note><pitch><step>B</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type><staff>1</staff></note><note><pitch><step>A</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type><staff>1</staff></note><note><pitch><step>G</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type><staff>1</staff></note><backup><duration>4</duration></backup><note><pitch><step>C</step><octave>3</octave></pitch><duration>4</duration><voice>5</voice><type>whole</type><staff>2</staff></note><note><chord/><pitch><step>G</step><octave>3</octave></pitch><duration>4</duration><voice>5</voice><type>whole</type><staff>2</staff></note></measure><measure number="4"><note><pitch><step>F</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type><staff>1</staff></note><note><pitch><step>E</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type><staff>1</staff></note><note><pitch><step>D</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type><staff>1</staff></note><note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type><staff>1</staff></note><backup><duration>4</duration></backup><note><pitch><step>C</step><octave>3</octave></pitch><duration>4</duration><voice>5</voice><type>whole</type><staff>2</staff></note><note><chord/><pitch><step>G</step><octave>3</octave></pitch><duration>4</duration><voice>5</voice><type>whole</type><staff>2</staff></note></measure></part></score-partwise>
"""#

    func testEventsMatchOSMDCursorSteps() throws {
        let score = try MusicXMLParser.parse(string: Self.xml)
        // OSMD cursor steps (source measure index, beat in measure, enrolled beat).
        var expected: [(Int, Double, Double)] = []
        for (pass, m) in [0, 1, 0, 1, 2, 3].enumerated() {
            for b in 0..<4 { expected.append((m, Double(b), Double(pass * 4 + b))) }
        }
        XCTAssertEqual(score.events.count, expected.count)
        for (e, x) in zip(score.events, expected) {
            XCTAssertEqual(e.sourceMeasureIndex, x.0)
            XCTAssertEqual(e.beatInMeasure, x.1, accuracy: 1e-9)
            XCTAssertEqual(e.beat, x.2, accuracy: 1e-9)
        }
        // Downbeats carry the held left-hand chord (C3 + G3) with the melody note.
        XCTAssertEqual(score.events[0].pitches, [48, 55, 60])
        XCTAssertEqual(score.title, "Test Piece")
    }

    func testScoreTrackFollowsSynthesisedPerformanceThroughRepeat() throws {
        let score = try MusicXMLParser.parse(string: Self.xml)
        let sync = SyncMap(bpm: 90, offset: 1.5)
        let track = FollowTrack.fromScore(score, syncMap: sync)
        let follower = ScoreFollower(track: track)
        follower.reset(toVideoTime: 1.0)
        var notes: [SynthPiano.Note] = []
        for e in score.events {
            for p in e.pitches {
                let held = e.beatInMeasure == 0 && p < 60 ? 3.6 : 0.9
                notes.append(.init(midi: p, start: 0.5 + e.beat, duration: held, velocity: 0.6))
            }
        }
        let sr = 44_100.0
        let audio = SynthPiano.render(notes, sampleRate: sr, length: 26, noiseLevel: 0.002)
        let analyzer = OnsetAnalyzer(sampleRate: sr)
        var positions: [Int] = []
        var i = 0
        while i < audio.count {
            let end = min(audio.count, i + 2048)
            for o in analyzer.process(Array(audio[i..<end])) { positions.append(follower.process(o, at: o.time).eventIndex) }
            i = end
        }
        XCTAssertEqual(positions, Array(0..<24))
        // One beat per second against a 90 BPM video (0.667 s per beat).
        XCTAssertEqual(follower.state.tempoRatio ?? 0, 60.0 / 90.0, accuracy: 0.08)
        // The follower's sheet position after the repeat points at the second measure 2 pass.
        let e = track.events[7]
        XCTAssertEqual(e.sourceMeasureIndex, 1)
        XCTAssertEqual(track.events[9].sourceMeasureIndex, 0)
    }
}
