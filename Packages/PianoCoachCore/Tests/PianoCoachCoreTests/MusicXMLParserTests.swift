import XCTest
@testable import PianoCoachCore

final class MusicXMLParserTests: XCTestCase {
    // MARK: - Helpers

    /// A one-part `score-partwise` document around the given measures.
    private func partwise(_ measures: String, header: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          \(header)
          <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
          <part id="P1">
        \(measures)
          </part>
        </score-partwise>
        """
    }

    /// A pitched note. `tie` adds `<tie type=…/>` elements (e.g. ["stop", "start"]).
    private func note(_ step: String, _ octave: Int, _ duration: Int, alter: String? = nil, chord: Bool = false,
                      tie: [String] = [], staff: Int? = nil) -> String {
        var s = "<note>"
        if chord { s += "<chord/>" }
        s += "<pitch><step>\(step)</step>"
        if let alter = alter { s += "<alter>\(alter)</alter>" }
        s += "<octave>\(octave)</octave></pitch><duration>\(duration)</duration>"
        for t in tie { s += "<tie type=\"\(t)\"/>" }
        if let staff = staff { s += "<staff>\(staff)</staff>" }
        if !tie.isEmpty { s += "<notations>" + tie.map { "<tied type=\"\($0)\"/>" }.joined() + "</notations>" }
        return s + "</note>\n"
    }

    private func rest(_ duration: Int) -> String {
        "<note><rest/><duration>\(duration)</duration></note>\n"
    }

    private func attributes(divisions: Int? = nil, beats: String? = nil, beatType: Int? = nil) -> String {
        var s = "<attributes>"
        if let d = divisions { s += "<divisions>\(d)</divisions>" }
        if let b = beats, let t = beatType { s += "<time><beats>\(b)</beats><beat-type>\(t)</beat-type></time>" }
        return s + "</attributes>\n"
    }

    private func beats(_ score: Score) -> [Double] { score.events.map(\.beat) }
    private func pitches(_ score: Score) -> [[Int]] { score.events.map(\.pitches) }

    private func assertBeats(_ actual: [Double], _ expected: [Double], accuracy: Double = 1e-9,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, "beats \(actual) != \(expected)", file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a, e, accuracy: accuracy, "beats \(actual) != \(expected)", file: file, line: line)
        }
    }

    /// Checks the invariants every parsed score must satisfy.
    private func assertConsistent(_ score: Score, file: StaticString = #filePath, line: UInt = #line) {
        var expectedStart = 0.0
        for (i, m) in score.measures.enumerated() {
            XCTAssertEqual(m.index, i, file: file, line: line)
            XCTAssertEqual(m.startBeat, expectedStart, accuracy: 1e-9, file: file, line: line)
            XCTAssertGreaterThan(m.lengthBeats, 0, file: file, line: line)
            expectedStart = m.endBeat
        }
        for (i, e) in score.events.enumerated() {
            XCTAssertEqual(e.index, i, file: file, line: line)
            if i > 0 { XCTAssertGreaterThan(e.beat, score.events[i - 1].beat, file: file, line: line) }
            let m = score.measures[e.measureIndex]
            XCTAssertEqual(e.sourceMeasureIndex, m.sourceIndex, file: file, line: line)
            XCTAssertEqual(e.beatInMeasure, e.beat - m.startBeat, accuracy: 1e-9, file: file, line: line)
            XCTAssertGreaterThanOrEqual(e.beatInMeasure, -1e-9, file: file, line: line)
            XCTAssertLessThan(e.beatInMeasure, m.lengthBeats, file: file, line: line)
            XCTAssertEqual(e.pitches, Array(Set(e.pitches)).sorted(), file: file, line: line)
            XCTAssertFalse(e.pitches.isEmpty, file: file, line: line)
            XCTAssertGreaterThan(e.durationBeats, 0, file: file, line: line)
        }
    }

    // MARK: - Simple melody

    static let twinkle = """
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
    <score-partwise version="4.0">
      <work><work-title>Twinkle, Twinkle &amp; Shine</work-title></work>
      <movement-title>Ignored Movement Title</movement-title>
      <identification>
        <creator type="lyricist">Jane Taylor</creator>
        <creator type="composer">Traditional</creator>
      </identification>
      <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
      <part id="P1">
        <measure number="1">
          <attributes>
            <divisions>1</divisions>
            <key><fifths>0</fifths></key>
            <time><beats>4</beats><beat-type>4</beat-type></time>
            <clef><sign>G</sign><line>2</line></clef>
          </attributes>
          <direction placement="above">
            <direction-type><words>Moderato</words></direction-type>
            <sound tempo="96"/>
          </direction>
          <note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type></note>
          <note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type></note>
          <note><pitch><step>G</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type></note>
          <note><pitch><step>G</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type></note>
        </measure>
        <measure number="2">
          <note><pitch><step>A</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type></note>
          <note><pitch><step>A</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type></note>
          <note><pitch><step>G</step><octave>4</octave></pitch><duration>2</duration><voice>1</voice><type>half</type></note>
        </measure>
        <measure number="3">
          <note><pitch><step>F</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type></note>
          <note><rest/><duration>1</duration><voice>1</voice><type>quarter</type></note>
          <note><pitch><step>E</step><octave>4</octave></pitch><duration>2</duration><voice>1</voice><type>half</type></note>
        </measure>
      </part>
    </score-partwise>
    """

    func testSimpleMelody() throws {
        let score = try MusicXMLParser.parse(string: Self.twinkle)
        assertConsistent(score)
        XCTAssertEqual(score.title, "Twinkle, Twinkle & Shine")
        XCTAssertEqual(score.composer, "Traditional")
        XCTAssertEqual(score.initialTempoBPM, 96)

        XCTAssertEqual(score.measures.map(\.number), ["1", "2", "3"])
        XCTAssertEqual(score.measures.map(\.sourceIndex), [0, 1, 2])
        XCTAssertEqual(score.measures.map(\.startBeat), [0, 4, 8])
        XCTAssertEqual(score.measures.map(\.lengthBeats), [4, 4, 4])
        XCTAssertEqual(score.measures.map(\.timeSignature), Array(repeating: .common, count: 3))
        XCTAssertEqual(score.totalBeats, 12)

        // The rest at beat 9 produces no event.
        XCTAssertEqual(beats(score), [0, 1, 2, 3, 4, 5, 6, 8, 10])
        XCTAssertEqual(pitches(score), [[60], [60], [67], [67], [69], [69], [67], [65], [64]])
        XCTAssertEqual(score.events.map(\.durationBeats), [1, 1, 1, 1, 1, 1, 2, 2, 2])
        XCTAssertEqual(score.events.map(\.measureIndex), [0, 0, 0, 0, 1, 1, 1, 2, 2])
        XCTAssertEqual(score.events.map(\.beatInMeasure), [0, 1, 2, 3, 0, 1, 2, 0, 2])
    }

    func testParseDataMatchesParseString() throws {
        let fromString = try MusicXMLParser.parse(string: Self.twinkle)
        let fromData = try MusicXMLParser.parse(data: Data(Self.twinkle.utf8))
        XCTAssertEqual(fromString, fromData)
    }

    // MARK: - Piano grand staff

    func testGrandStaffWithBackupAndChords() throws {
        let xml = partwise("""
        <measure number="1">
          <attributes><divisions>2</divisions><time><beats>4</beats><beat-type>4</beat-type></time><staves>2</staves></attributes>
          \(note("C", 5, 2, staff: 1))
          \(note("E", 5, 2, staff: 1))
          \(note("G", 5, 2, chord: true, staff: 1))
          \(note("C", 5, 4, staff: 1))
          <backup><duration>8</duration></backup>
          \(note("C", 3, 8, staff: 2))
          \(note("G", 3, 8, chord: true, staff: 2))
          \(note("C", 4, 8, chord: true, staff: 2))
        </measure>
        <measure number="2">
          \(note("D", 5, 1, staff: 1))\(note("E", 5, 1, staff: 1))\(note("F", 5, 1, staff: 1))\(note("G", 5, 1, staff: 1))
          \(note("A", 5, 4, staff: 1))
          <backup><duration>8</duration></backup>
          \(note("G", 2, 2, staff: 2))
          \(rest(2))
          \(note("B", 2, 4, staff: 2))
          \(note("D", 3, 4, chord: true, staff: 2))
        </measure>
        """)
        let score = try MusicXMLParser.parse(string: xml)
        assertConsistent(score)
        XCTAssertEqual(score.measures.map(\.lengthBeats), [4, 4])
        XCTAssertEqual(beats(score), [0, 1, 2, 4, 4.5, 5, 5.5, 6])
        XCTAssertEqual(pitches(score), [[48, 55, 60, 72], [76, 79], [72], [43, 74], [76], [77], [79], [47, 50, 81]])
        XCTAssertEqual(score.events.map(\.durationBeats), [1, 1, 2, 0.5, 0.5, 0.5, 0.5, 2])
        XCTAssertEqual(score.events.map(\.measureIndex), [0, 0, 0, 1, 1, 1, 1, 1])
    }

    func testForwardAndDuplicatePitchesAcrossVoices() throws {
        let xml = partwise("""
        <measure number="1">
          \(attributes(divisions: 1, beats: "4", beatType: 4))
          \(note("C", 5, 4))
          <backup><duration>4</duration></backup>
          <forward><duration>2</duration></forward>
          \(note("E", 4, 2))
          <backup><duration>4</duration></backup>
          \(note("C", 5, 1))
          \(note("E", 4, 3, chord: true))
        </measure>
        """)
        let score = try MusicXMLParser.parse(string: xml)
        assertConsistent(score)
        // Voice 3 repeats C5 at beat 0: merged and de-duplicated.
        XCTAssertEqual(beats(score), [0, 2])
        XCTAssertEqual(pitches(score), [[64, 72], [64]])
        XCTAssertEqual(score.events.last?.durationBeats, 2)
    }

    // MARK: - Ties

    func testTiesAcrossBarlinesAreNotNewAttacks() throws {
        let xml = partwise("""
        <measure number="1">
          \(attributes(divisions: 1, beats: "4", beatType: 4))
          \(note("C", 4, 1))\(note("D", 4, 1))\(note("E", 4, 2, tie: ["start"]))
        </measure>
        <measure number="2">
          \(note("E", 4, 1, tie: ["stop"]))\(note("F", 4, 1))\(note("G", 4, 2, tie: ["start"]))
        </measure>
        <measure number="3">
          \(note("G", 4, 4, tie: ["stop", "start"]))
          \(note("B", 3, 4, chord: true))
        </measure>
        <measure number="4">
          \(note("G", 4, 2, tie: ["stop"]))\(note("C", 5, 2))
        </measure>
        """)
        let score = try MusicXMLParser.parse(string: xml)
        assertConsistent(score)
        XCTAssertEqual(beats(score), [0, 1, 2, 5, 6, 8, 14])
        XCTAssertEqual(pitches(score), [[60], [62], [64], [65], [67], [59], [72]])
        XCTAssertEqual(score.events.map(\.durationBeats), [1, 1, 3, 1, 2, 6, 2])
        XCTAssertEqual(score.events.map(\.measureIndex), [0, 0, 0, 1, 1, 2, 3])
        XCTAssertEqual(score.measures.map(\.lengthBeats), [4, 4, 4, 4])
    }

    func testTiedNotationWithoutTieElementIsAContinuation() throws {
        let xml = partwise("""
        <measure number="1">
          \(attributes(divisions: 1, beats: "2", beatType: 4))
          <note><pitch><step>A</step><octave>4</octave></pitch><duration>2</duration><notations><tied type="start"/></notations></note>
        </measure>
        <measure number="2">
          <note><pitch><step>A</step><octave>4</octave></pitch><duration>1</duration><notations><tied type="stop"/></notations></note>
          \(note("B", 4, 1))
        </measure>
        """)
        let score = try MusicXMLParser.parse(string: xml)
        XCTAssertEqual(beats(score), [0, 3])
        XCTAssertEqual(pitches(score), [[69], [71]])
    }

    // MARK: - Pickup, meters, divisions

    func testPickupMeasure() throws {
        let xml = partwise("""
        <measure number="0" implicit="yes">
          \(attributes(divisions: 1, beats: "3", beatType: 4))
          \(note("G", 4, 1))
        </measure>
        <measure number="1">\(note("C", 5, 1))\(note("D", 5, 1))\(note("E", 5, 1))</measure>
        <measure number="2">\(note("F", 5, 2))</measure>
        """)
        let score = try MusicXMLParser.parse(string: xml)
        assertConsistent(score)
        XCTAssertEqual(score.measures.map(\.number), ["0", "1", "2"])
        XCTAssertEqual(score.measures.map(\.startBeat), [0, 1, 4])
        XCTAssertEqual(score.measures.map(\.lengthBeats), [1, 3, 2])
        XCTAssertEqual(score.measures.map(\.timeSignature), Array(repeating: TimeSignature(beats: 3, beatType: 4), count: 3))
        XCTAssertEqual(beats(score), [0, 1, 2, 3, 4])
        XCTAssertEqual(score.events.last?.durationBeats, 2)
        XCTAssertEqual(score.measure(numbered: 1)?.index, 1)
        XCTAssertEqual(score.measure(numbered: 2)?.startBeat, 4)
        XCTAssertEqual(score.measureIndex(atBeat: 0.5), 0)
        XCTAssertEqual(score.measureIndex(atBeat: 3.5), 1)
    }

    func testCompoundSimpleAndAdditiveMeters() throws {
        let xml = partwise("""
        <measure number="1">
          \(attributes(divisions: 2, beats: "6", beatType: 8))
          \(note("C", 4, 3))\(note("E", 4, 3))
        </measure>
        <measure number="2">
          \(note("G", 4, 1))\(note("A", 4, 1))\(note("B", 4, 1))\(note("C", 5, 1))\(note("D", 5, 1))\(note("E", 5, 1))
        </measure>
        <measure number="3">
          \(attributes(beats: "3", beatType: 4))
        </measure>
        <measure number="4">\(note("C", 5, 4))\(rest(2))</measure>
        <measure number="5">
          \(attributes(beats: "3+2", beatType: 8))
          \(note("C", 4, 3))\(note("D", 4, 2))
        </measure>
        """)
        let score = try MusicXMLParser.parse(string: xml)
        assertConsistent(score)
        XCTAssertEqual(score.measures.map(\.timeSignature), [
            TimeSignature(beats: 6, beatType: 8), TimeSignature(beats: 6, beatType: 8),
            TimeSignature(beats: 3, beatType: 4), TimeSignature(beats: 3, beatType: 4),
            TimeSignature(beats: 5, beatType: 8),
        ])
        // Measure 3 is empty, so it takes its 3/4 signature's length.
        XCTAssertEqual(score.measures.map(\.lengthBeats), [3, 3, 3, 3, 2.5])
        XCTAssertEqual(score.measures.map(\.startBeat), [0, 3, 6, 9, 12])
        XCTAssertEqual(beats(score), [0, 1.5, 3, 3.5, 4, 4.5, 5, 5.5, 9, 12, 13.5])
        XCTAssertEqual(score.events.map(\.measureIndex), [0, 0, 1, 1, 1, 1, 1, 1, 3, 4, 4])
        XCTAssertEqual(score.events[8].durationBeats, 3)  // the C5 half note runs until measure 5
        XCTAssertEqual(score.events.last?.durationBeats, 1)
        XCTAssertEqual(score.totalBeats, 14.5)
    }

    func testCompositeTimeSignature() throws {
        let xml = partwise("""
        <measure number="1">
          <attributes><divisions>2</divisions><time><beats>3</beats><beat-type>8</beat-type><beats>2</beats><beat-type>4</beat-type></time></attributes>
          \(note("C", 4, 3))\(note("D", 4, 4))
        </measure>
        """)
        let score = try MusicXMLParser.parse(string: xml)
        XCTAssertEqual(score.measures[0].timeSignature, TimeSignature(beats: 7, beatType: 8))
        XCTAssertEqual(score.measures[0].lengthBeats, 3.5)
    }

    func testDivisionsChangeBetweenAndWithinMeasures() throws {
        let xml = partwise("""
        <measure number="1">
          \(attributes(divisions: 1, beats: "4", beatType: 4))
          \(note("C", 4, 1))\(note("D", 4, 1))\(note("E", 4, 1))\(note("F", 4, 1))
        </measure>
        <measure number="2">
          \(attributes(divisions: 4))
          \(note("G", 4, 2))\(note("A", 4, 2))\(note("B", 4, 2))\(note("C", 5, 2))
          \(note("D", 5, 2))\(note("E", 5, 2))\(note("F", 5, 2))\(note("G", 5, 2))
        </measure>
        <measure number="3">
          \(attributes(divisions: 3))
          \(note("C", 5, 1))\(note("D", 5, 1))\(note("E", 5, 1))\(note("F", 5, 3))\(note("G", 5, 6))
        </measure>
        <measure number="4">
          \(note("C", 4, 3))
          \(attributes(divisions: 2))
          \(note("D", 4, 1))\(note("E", 4, 1))\(note("F", 4, 4))
        </measure>
        """)
        let score = try MusicXMLParser.parse(string: xml)
        assertConsistent(score)
        XCTAssertEqual(score.measures.map(\.lengthBeats), [4, 4, 4, 4])
        assertBeats(beats(score), [0, 1, 2, 3,
                                   4, 4.5, 5, 5.5, 6, 6.5, 7, 7.5,
                                   8, 8 + 1.0 / 3, 8 + 2.0 / 3, 9, 10,
                                   12, 13, 13.5, 14])
        XCTAssertEqual(score.events[12].durationBeats, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(score.events.last?.durationBeats, 2)
    }

    // MARK: - Multiple parts

    func testTwoPartsWithDifferentDivisionsAreMerged() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="3.1">
          <movement-title>Duet</movement-title>
          <part-list>
            <score-part id="P1"><part-name>Flute</part-name></score-part>
            <score-part id="P2"><part-name>Cello</part-name></score-part>
          </part-list>
          <part id="P1">
            <measure number="1">
              \(attributes(divisions: 1, beats: "4", beatType: 4))
              \(note("C", 5, 2))\(note("D", 5, 2))
            </measure>
            <measure number="2">\(note("E", 5, 4))</measure>
          </part>
          <part id="P2">
            <measure number="1">
              \(attributes(divisions: 4, beats: "4", beatType: 4))
              \(note("C", 3, 4))\(note("E", 3, 4))\(note("G", 3, 8, tie: ["start"]))
            </measure>
            <measure number="2">
              \(note("G", 3, 4, tie: ["stop"]))\(note("C", 3, 4))
            </measure>
          </part>
        </score-partwise>
        """
        let score = try MusicXMLParser.parse(string: xml)
        assertConsistent(score)
        XCTAssertEqual(score.title, "Duet")
        XCTAssertNil(score.composer)
        XCTAssertNil(score.initialTempoBPM)
        XCTAssertEqual(score.measures.map(\.lengthBeats), [4, 4])
        XCTAssertEqual(beats(score), [0, 1, 2, 4, 5])
        // At beat 4 the cello's G3 is a tied continuation: only the flute's E5 is a new attack.
        XCTAssertEqual(pitches(score), [[48, 72], [52], [55, 74], [76], [48]])
        XCTAssertEqual(score.events.map(\.durationBeats), [1, 1, 2, 1, 1])
    }

    func testMeasureLengthIsTheLongestPart() throws {
        let xml = """
        <score-partwise>
          <part-list><score-part id="A"/><score-part id="B"/></part-list>
          <part id="A">
            <measure number="1">\(attributes(divisions: 1, beats: "4", beatType: 4))\(note("C", 5, 1))</measure>
            <measure number="2">\(note("D", 5, 1))</measure>
          </part>
          <part id="B">
            <measure number="1">\(attributes(divisions: 1))\(note("C", 3, 3))</measure>
            <measure number="2">\(note("D", 3, 1))</measure>
            <measure number="3">\(note("E", 3, 2))</measure>
          </part>
        </score-partwise>
        """
        let score = try MusicXMLParser.parse(string: xml)
        assertConsistent(score)
        // Lengths come from the content (3 and 1 beats); part B's extra measure is still included.
        XCTAssertEqual(score.measures.map(\.lengthBeats), [3, 1, 2])
        XCTAssertEqual(score.measures.map(\.number), ["1", "2", "3"])
        XCTAssertEqual(beats(score), [0, 3, 4])
    }

    // MARK: - Grace, cue and unpitched notes

    func testGraceCueAndUnpitchedNotesAreNotAttacks() throws {
        let xml = partwise("""
        <measure number="1">
          \(attributes(divisions: 2, beats: "4", beatType: 4))
          <note><grace/><pitch><step>D</step><octave>4</octave></pitch><voice>1</voice><type>eighth</type></note>
          \(note("C", 4, 2))
          <note><grace slash="yes"/><pitch><step>F</step><octave>4</octave></pitch><voice>1</voice><type>16th</type></note>
          <note><grace slash="yes"/><chord/><pitch><step>A</step><octave>4</octave></pitch><voice>1</voice><type>16th</type></note>
          \(note("E", 4, 2))
          <note><cue/><pitch><step>G</step><octave>4</octave></pitch><duration>2</duration><type>quarter</type></note>
          <note><unpitched><display-step>E</display-step><display-octave>4</display-octave></unpitched><duration>2</duration></note>
        </measure>
        <measure number="2">\(note("C", 5, 8))</measure>
        """)
        let score = try MusicXMLParser.parse(string: xml)
        assertConsistent(score)
        XCTAssertEqual(beats(score), [0, 1, 4])
        XCTAssertEqual(pitches(score), [[60], [64], [72]])
        XCTAssertEqual(score.events[1].durationBeats, 3)
        XCTAssertEqual(score.measures.map(\.lengthBeats), [4, 4])
    }

    func testAlterationsAndMissingMeasureNumbers() throws {
        let xml = partwise("""
        <measure>
          \(attributes(divisions: 1, beats: "4", beatType: 4))
          \(note("B", 3, 1, alter: "-1"))\(note("F", 4, 1, alter: "1"))\(note("C", 4, 1, alter: "0.5"))\(note("E", 4, 1, alter: "-2"))
        </measure>
        <measure number="">\(note("c", 4, 4, alter: "+1.0"))</measure>
        """)
        let score = try MusicXMLParser.parse(string: xml)
        XCTAssertEqual(score.measures.map(\.number), ["1", "2"])
        XCTAssertEqual(pitches(score), [[58], [66], [61], [62], [61]])
    }

    // MARK: - Repeats

    private let forwardRepeat = #"<barline location="left"><bar-style>heavy-light</bar-style><repeat direction="forward"/></barline>"#
    private func backwardRepeat(times: Int? = nil) -> String {
        let t = times.map { #" times="\#($0)""# } ?? ""
        return #"<barline location="right"><bar-style>light-heavy</bar-style><repeat direction="backward"\#(t)/></barline>"#
    }
    private func endingStart(_ number: String) -> String {
        #"<barline location="left"><ending number="\#(number)" type="start"/></barline>"#
    }
    private func endingStopWithRepeat(_ number: String, times: Int? = nil) -> String {
        let t = times.map { #" times="\#($0)""# } ?? ""
        return #"<barline location="right"><bar-style>light-heavy</bar-style><ending number="\#(number)" type="stop"/><repeat direction="backward"\#(t)/></barline>"#
    }
    private func endingDiscontinue(_ number: String) -> String {
        #"<barline location="right"><ending number="\#(number)" type="discontinue"/></barline>"#
    }

    /// Measures 1-4 with first and second endings: plays 1, 2, 3, 1, 2, 4.
    private var voltaScore: String {
        partwise("""
        <measure number="1">\(forwardRepeat)\(attributes(divisions: 1, beats: "4", beatType: 4))\(note("C", 4, 4))</measure>
        <measure number="2">\(note("D", 4, 4))</measure>
        <measure number="3">\(endingStart("1"))\(note("E", 4, 4))\(endingStopWithRepeat("1"))</measure>
        <measure number="4">\(endingStart("2"))\(note("F", 4, 4))\(endingDiscontinue("2"))</measure>
        """)
    }

    func testRepeatWithFirstAndSecondEndings() throws {
        let score = try MusicXMLParser.parse(string: voltaScore)
        assertConsistent(score)
        XCTAssertEqual(score.measures.map(\.number), ["1", "2", "3", "1", "2", "4"])
        XCTAssertEqual(score.measures.map(\.sourceIndex), [0, 1, 2, 0, 1, 3])
        XCTAssertEqual(score.measures.map(\.index), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(score.measures.map(\.startBeat), [0, 4, 8, 12, 16, 20])
        XCTAssertEqual(beats(score), [0, 4, 8, 12, 16, 20])
        XCTAssertEqual(pitches(score), [[60], [62], [64], [60], [62], [65]])
        XCTAssertEqual(score.events.map(\.sourceMeasureIndex), [0, 1, 2, 0, 1, 3])
        XCTAssertEqual(score.events.map(\.measureIndex), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(score.events.map(\.durationBeats), [4, 4, 4, 4, 4, 4])
        XCTAssertEqual(score.totalBeats, 24)
        // "Measure 1" is the first time it is played.
        XCTAssertEqual(score.measure(numbered: 1)?.index, 0)
        XCTAssertEqual(score.measure(numbered: 4)?.index, 5)
    }

    func testRepeatsLeftInFileOrderWhenNotUnrolled() throws {
        let score = try MusicXMLParser.parse(string: voltaScore, unrollRepeats: false)
        assertConsistent(score)
        XCTAssertEqual(score.measures.map(\.number), ["1", "2", "3", "4"])
        XCTAssertEqual(score.measures.map(\.sourceIndex), [0, 1, 2, 3])
        XCTAssertEqual(beats(score), [0, 4, 8, 12])
        XCTAssertEqual(pitches(score), [[60], [62], [64], [65]])
    }

    /// One whole note per measure (C4, D4, E4, …) with the given barline markup per measure.
    private func repeatScore(_ barlines: [(left: String, right: String)]) -> String {
        let steps = ["C", "D", "E", "F", "G", "A", "B"]
        var measures = ""
        for (i, b) in barlines.enumerated() {
            let attrs = i == 0 ? attributes(divisions: 1, beats: "4", beatType: 4) : ""
            measures += "<measure number=\"\(i + 1)\">\(b.left)\(attrs)\(note(steps[i % 7], 4, 4))\(b.right)</measure>\n"
        }
        return partwise(measures)
    }

    private func playedNumbers(_ xml: String) throws -> [String] {
        let score = try MusicXMLParser.parse(string: xml)
        assertConsistent(score)
        XCTAssertEqual(score.events.map(\.sourceMeasureIndex), score.measures.map(\.sourceIndex))
        return score.measures.map(\.number)
    }

    func testBackwardRepeatsWithoutForwardRepeat() throws {
        // Second repeat goes back to the measure after the first completed repeat.
        let xml = repeatScore([("", ""), ("", backwardRepeat()), ("", ""), ("", backwardRepeat())])
        XCTAssertEqual(try playedNumbers(xml), ["1", "2", "1", "2", "3", "4", "3", "4"])
    }

    func testRepeatTimesAttribute() throws {
        let xml = repeatScore([(forwardRepeat, ""), ("", backwardRepeat(times: 3)), ("", "")])
        XCTAssertEqual(try playedNumbers(xml), ["1", "2", "1", "2", "1", "2", "3"])
    }

    func testBackToBackRepeats() throws {
        let xml = repeatScore([(forwardRepeat, ""), ("", backwardRepeat()), (forwardRepeat, ""), ("", backwardRepeat())])
        XCTAssertEqual(try playedNumbers(xml), ["1", "2", "1", "2", "3", "4", "3", "4"])
    }

    func testEndingForSeveralPasses() throws {
        // Ending "1, 2" is played on passes 1 and 2, ending "3" on the third pass.
        let xml = repeatScore([
            (forwardRepeat, ""),
            (endingStart("1, 2"), endingStopWithRepeat("1, 2", times: 3)),
            (endingStart("3"), endingDiscontinue("3")),
            ("", ""),
        ])
        XCTAssertEqual(try playedNumbers(xml), ["1", "2", "1", "2", "1", "3", "4"])
    }

    func testEndingForSeveralPassesWithoutTimesAttribute() throws {
        let xml = repeatScore([
            ("", ""),
            (endingStart("1,2"), endingStopWithRepeat("1,2")),
            (endingStart("3"), endingDiscontinue("3")),
        ])
        XCTAssertEqual(try playedNumbers(xml), ["1", "2", "1", "2", "1", "3"])
    }

    func testRepeatAfterVoltaSectionStartsAfterTheSecondEnding() throws {
        let xml = repeatScore([
            (forwardRepeat, ""),
            (endingStart("1"), endingStopWithRepeat("1")),
            (endingStart("2"), endingDiscontinue("2")),
            ("", ""),
            ("", backwardRepeat()),
        ])
        XCTAssertEqual(try playedNumbers(xml), ["1", "2", "1", "3", "4", "5", "4", "5"])
    }

    func testMultiMeasureEndings() throws {
        let xml = repeatScore([
            (forwardRepeat, ""),
            (endingStart("1"), ""),
            ("", endingStopWithRepeat("1")),
            (endingStart("2"), ""),
            ("", endingDiscontinue("2")),
            ("", ""),
        ])
        XCTAssertEqual(try playedNumbers(xml), ["1", "2", "3", "1", "4", "5", "6"])
    }

    func testPerformanceOrderUnitCases() {
        typealias R = MusicXMLParser.RepeatInfo
        XCTAssertEqual(MusicXMLParser.performanceOrder([R(), R(), R()]), [0, 1, 2])
        XCTAssertEqual(MusicXMLParser.performanceOrder([]), [])
        // A single measure that repeats itself.
        XCTAssertEqual(MusicXMLParser.performanceOrder([R(), R(hasForward: true, hasBackward: true), R()]), [0, 1, 1, 2])
        XCTAssertEqual(MusicXMLParser.endingNumbers("1, 2"), [1, 2])
        XCTAssertEqual(MusicXMLParser.endingNumbers("1."), [1])
        XCTAssertEqual(MusicXMLParser.endingNumbers("1-3"), [1, 2, 3])
        XCTAssertNil(MusicXMLParser.endingNumbers(""))
    }

    // MARK: - Tempo

    private func tempoScore(_ directions: String) -> String {
        partwise("""
        <measure number="1">\(attributes(divisions: 1, beats: "4", beatType: 4))\(directions)\(note("C", 4, 4))</measure>
        """)
    }

    private func metronome(_ unit: String, dots: Int = 0, perMinute: String) -> String {
        let dotXML = String(repeating: "<beat-unit-dot/>", count: dots)
        return "<direction><direction-type><metronome><beat-unit>\(unit)</beat-unit>\(dotXML)<per-minute>\(perMinute)</per-minute></metronome></direction-type></direction>"
    }

    func testTempoFromMetronome() throws {
        XCTAssertEqual(try MusicXMLParser.parse(string: tempoScore(metronome("quarter", dots: 1, perMinute: "60"))).initialTempoBPM, 90)
        XCTAssertEqual(try MusicXMLParser.parse(string: tempoScore(metronome("half", perMinute: "50"))).initialTempoBPM, 100)
        XCTAssertEqual(try MusicXMLParser.parse(string: tempoScore(metronome("eighth", perMinute: "120"))).initialTempoBPM, 60)
        XCTAssertEqual(try MusicXMLParser.parse(string: tempoScore(metronome("quarter", perMinute: "c. 72"))).initialTempoBPM, 72)
        XCTAssertEqual(try MusicXMLParser.parse(string: tempoScore(metronome("half", dots: 2, perMinute: "40"))).initialTempoBPM, 140)
    }

    func testSoundTempoTakesPrecedenceOverMetronome() throws {
        let xml = partwise("""
        <measure number="1">\(attributes(divisions: 1, beats: "4", beatType: 4))\(metronome("quarter", perMinute: "80"))\(note("C", 4, 4))</measure>
        <measure number="2"><direction><direction-type><words>a tempo</words></direction-type><sound tempo="72.5"/></direction>\(note("D", 4, 4))</measure>
        """)
        XCTAssertEqual(try MusicXMLParser.parse(string: xml).initialTempoBPM, 72.5)
    }

    func testMetricModulationIsNotATempo() throws {
        let modulation = "<direction><direction-type><metronome><beat-unit>quarter</beat-unit><beat-unit>eighth</beat-unit></metronome></direction-type></direction>"
        XCTAssertNil(try MusicXMLParser.parse(string: tempoScore(modulation)).initialTempoBPM)
    }

    // MARK: - Encodings and document formats

    private func assertTwinkle(_ score: Score, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(score.title, "Twinkle, Twinkle & Shine", file: file, line: line)
        XCTAssertEqual(score.events.count, 9, file: file, line: line)
        XCTAssertEqual(score.events.first?.pitches, [60], file: file, line: line)
    }

    func testUTF16WithBOMAndDoctype() throws {
        let text = Self.twinkle.replacingOccurrences(of: #"encoding="UTF-8""#, with: #"encoding="UTF-16""#)
        let le = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        let be = Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!
        assertTwinkle(try MusicXMLParser.parse(data: le))
        assertTwinkle(try MusicXMLParser.parse(data: be))
        // A string whose declaration still claims UTF-16.
        assertTwinkle(try MusicXMLParser.parse(string: text))
    }

    func testUTF8WithBOM() throws {
        assertTwinkle(try MusicXMLParser.parse(data: Data([0xEF, 0xBB, 0xBF]) + Data(Self.twinkle.utf8)))
        assertTwinkle(try MusicXMLParser.parse(string: "\u{FEFF}" + Self.twinkle))
    }

    func testNonASCIITitle() throws {
        let xml = partwise("<measure number=\"1\">\(note("C", 4, 4))</measure>",
                           header: "<work><work-title>Für Elise — «Bagatelle»</work-title></work>")
        XCTAssertEqual(try MusicXMLParser.parse(string: xml).title, "Für Elise — «Bagatelle»")
    }

    func testRejectsTimewise() {
        let xml = """
        <?xml version="1.0"?>
        <score-timewise version="4.0"><part-list/><measure number="1"><part id="P1"/></measure></score-timewise>
        """
        XCTAssertThrowsError(try MusicXMLParser.parse(string: xml)) { error in
            guard case MusicXMLError.unsupportedFormat = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertThrowsError(try MusicXMLParser.parse(string: "<html><body/></html>")) { error in
            guard case MusicXMLError.unsupportedFormat = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testRejectsMalformedXML() {
        for bad in ["<score-partwise><part></score-partwise>", "", "not xml at all", "<a>"] {
            XCTAssertThrowsError(try MusicXMLParser.parse(string: bad), bad) { error in
                guard case MusicXMLError.invalidXML = error else { return XCTFail("unexpected \(error) for \(bad)") }
            }
        }
    }

    func testScoreWithoutNotesThrows() {
        let restsOnly = partwise("<measure number=\"1\">\(attributes(divisions: 1, beats: "4", beatType: 4))\(rest(4))</measure>")
        XCTAssertThrowsError(try MusicXMLParser.parse(string: restsOnly)) { XCTAssertEqual($0 as? MusicXMLError, .noNotes) }
        let noParts = "<score-partwise><part-list/></score-partwise>"
        XCTAssertThrowsError(try MusicXMLParser.parse(string: noParts)) { XCTAssertEqual($0 as? MusicXMLError, .noNotes) }
    }

    // MARK: - Size

    func testLargeScoreParsesQuickly() throws {
        // 1500 grand-staff measures: 8 eighth notes over a whole-note chord (about 16k notes).
        var measures = ""
        let steps = ["C", "D", "E", "F", "G", "A", "B", "C"]
        for i in 0..<1500 {
            measures += "<measure number=\"\(i + 1)\">"
            if i == 0 { measures += attributes(divisions: 2, beats: "4", beatType: 4) }
            for (k, s) in steps.enumerated() { measures += note(s, k == 7 ? 6 : 5, 1, staff: 1) }
            measures += "<backup><duration>8</duration></backup>"
            measures += note("C", 3, 8, staff: 2) + note("G", 3, 8, chord: true, staff: 2)
            measures += "</measure>\n"
        }
        let xml = partwise(measures)
        let start = Date()
        let score = try MusicXMLParser.parse(string: xml)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(score.measures.count, 1500)
        XCTAssertEqual(score.events.count, 1500 * 8)
        XCTAssertEqual(score.events.last?.beat, 1499 * 4 + 3.5)
        XCTAssertEqual(score.events[8].pitches, [48, 55, 72])
        XCTAssertLessThan(elapsed, 20)
    }
}
