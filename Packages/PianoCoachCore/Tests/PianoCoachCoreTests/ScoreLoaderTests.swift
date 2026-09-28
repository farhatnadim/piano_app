import XCTest
@testable import PianoCoachCore

final class ScoreLoaderTests: XCTestCase {
    private static let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
    <score-partwise version="4.0">
      <work><work-title>Ode to Joy</work-title></work>
      <identification><creator type="composer">Ludwig van Beethoven</creator></identification>
      <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
      <part id="P1">
        <measure number="1">
          <attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
          <note><pitch><step>E</step><octave>4</octave></pitch><duration>1</duration></note>
          <note><pitch><step>E</step><octave>4</octave></pitch><duration>1</duration></note>
          <note><pitch><step>F</step><octave>4</octave></pitch><duration>1</duration></note>
          <note><pitch><step>G</step><octave>4</octave></pitch><duration>1</duration></note>
        </measure>
      </part>
    </score-partwise>
    """

    /// One quarter-note C4 at 120 BPM (ppq 480).
    private static let midi = Data([
        0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x01, 0x01, 0xE0,
        0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x13,
        0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,
        0x00, 0x90, 0x3C, 0x64,
        0x83, 0x60, 0x3C, 0x00,
        0x00, 0xFF, 0x2F, 0x00,
    ])

    // MARK: - loadScore

    func testLoadsMusicXML() throws {
        let score = try ScoreLoader.loadScore(from: Data(Self.xml.utf8), kind: .musicXML)
        XCTAssertEqual(score.title, "Ode to Joy")
        XCTAssertEqual(score.composer, "Ludwig van Beethoven")
        XCTAssertEqual(score.events.map(\.pitches), [[64], [64], [65], [67]])
    }

    func testLoadsCompressedMusicXML() throws {
        for fixture in [ZipFixtures.handmadeZip, ZipFixtures.streamedMXL, ZipFixtures.noContainerMXL] {
            let score = try ScoreLoader.loadScore(from: ZipFixtures.data(fixture), kind: .compressedMusicXML)
            XCTAssertEqual(score.title, "Zipped Song")
            XCTAssertEqual(score.events.map(\.beat), [0, 1, 2, 3])
            XCTAssertEqual(score.events.map(\.pitches), [[60], [62], [64], [65]])
        }
    }

    func testLoadsMIDI() throws {
        let score = try ScoreLoader.loadScore(from: Self.midi, kind: .midi)
        XCTAssertEqual(score.initialTempoBPM, 120)
        XCTAssertEqual(score.events.map(\.pitches), [[60]])
        XCTAssertEqual(score.events[0].durationBeats, 1)
    }

    func testPDFAndImagesAreNotScores() {
        for kind in [SheetKind.pdf, .image] {
            XCTAssertThrowsError(try ScoreLoader.loadScore(from: Data("%PDF-1.7".utf8), kind: kind)) {
                XCTAssertEqual($0 as? ScoreLoaderError, .notAScore(kind))
            }
        }
    }

    func testKindIsCorrectedByContent() throws {
        // A zipped score saved as ".xml", and a plain score saved as ".mxl".
        let zipped = try ScoreLoader.loadScore(from: ZipFixtures.data(ZipFixtures.streamedMXL), kind: .musicXML)
        XCTAssertEqual(zipped.title, "Zipped Song")
        let plain = try ScoreLoader.loadScore(from: Data(Self.xml.utf8), kind: .compressedMusicXML)
        XCTAssertEqual(plain.title, "Ode to Joy")
    }

    func testParserErrorsPropagate() {
        XCTAssertThrowsError(try ScoreLoader.loadScore(from: Data("<nope".utf8), kind: .musicXML)) { error in
            guard case MusicXMLError.invalidXML = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertThrowsError(try ScoreLoader.loadScore(from: Data("MThd".utf8), kind: .midi)) { error in
            XCTAssertNotNil(error as? MIDIFileError)
        }
        XCTAssertThrowsError(try ScoreLoader.loadScore(from: Data("PK\u{3}\u{4}broken".utf8), kind: .compressedMusicXML)) {
            XCTAssertEqual($0 as? ZipError, .notAZipArchive)
        }
    }

    // MARK: - musicXMLText

    func testMusicXMLTextForPlainUTF8() throws {
        XCTAssertEqual(try ScoreLoader.musicXMLText(from: Data(Self.xml.utf8), kind: .musicXML), Self.xml)
        XCTAssertEqual(try ScoreLoader.musicXMLText(from: Data([0xEF, 0xBB, 0xBF]) + Data(Self.xml.utf8), kind: .musicXML),
                       Self.xml)
    }

    func testMusicXMLTextForUTF16WithBOM() throws {
        let le = Data([0xFF, 0xFE]) + Self.xml.data(using: .utf16LittleEndian)!
        let be = Data([0xFE, 0xFF]) + Self.xml.data(using: .utf16BigEndian)!
        XCTAssertEqual(try ScoreLoader.musicXMLText(from: le, kind: .musicXML), Self.xml)
        XCTAssertEqual(try ScoreLoader.musicXMLText(from: be, kind: .musicXML), Self.xml)
    }

    func testMusicXMLTextFromMXLIsUnzipped() throws {
        let text = try XCTUnwrap(ScoreLoader.musicXMLText(from: ZipFixtures.data(ZipFixtures.handmadeZip),
                                                          kind: .compressedMusicXML))
        XCTAssertTrue(text.hasPrefix("<?xml"))
        XCTAssertTrue(text.contains("<work-title>Zipped Song</work-title>"))
        XCTAssertEqual(text.utf8.count, ZipFixtures.songLength)
    }

    func testMusicXMLTextIsNilForOtherKinds() throws {
        XCTAssertNil(try ScoreLoader.musicXMLText(from: Self.midi, kind: .midi))
        XCTAssertNil(try ScoreLoader.musicXMLText(from: Data("%PDF".utf8), kind: .pdf))
        XCTAssertNil(try ScoreLoader.musicXMLText(from: Data([0x89, 0x50, 0x4E, 0x47]), kind: .image))
    }

    func testUndecodableTextThrows() {
        let invalid = Data([0x3C, 0x61, 0x3E, 0xC3, 0x28, 0x80, 0xFE])  // "<a>" + invalid UTF-8
        XCTAssertThrowsError(try ScoreLoader.musicXMLText(from: invalid, kind: .musicXML)) {
            XCTAssertEqual($0 as? ScoreLoaderError, .unreadableText)
        }
    }

    func testLatin1DeclaredTextIsDecoded() throws {
        let text = #"<?xml version="1.0" encoding="ISO-8859-1"?><score-partwise><work><work-title>Café</work-title></work></score-partwise>"#
        let data = text.data(using: .isoLatin1)!
        XCTAssertEqual(try ScoreLoader.musicXMLText(from: data, kind: .musicXML), text)
    }

    // MARK: - MXLReader

    func testMXLUsesFirstRootfileOfContainer() throws {
        let data = try MXLReader.musicXMLData(fromMXL: ZipFixtures.data(ZipFixtures.handmadeZip))
        XCTAssertEqual(CRC32.checksum(data), ZipFixtures.songCRC)
    }

    func testMXLWithoutContainerFallsBackToFirstScoreEntry() throws {
        // Skips "readme.txt", "META-INF/manifest.xml" and "__MACOSX/…"; the extension check ignores case.
        let data = try MXLReader.musicXMLData(fromMXL: ZipFixtures.data(ZipFixtures.noContainerMXL))
        XCTAssertEqual(CRC32.checksum(data), ZipFixtures.songCRC)
    }

    func testMXLWithContainerPointingAtMissingFileFallsBack() throws {
        let data = try MXLReader.musicXMLData(fromMXL: ZipFixtures.data(ZipFixtures.brokenContainerMXL))
        XCTAssertEqual(CRC32.checksum(data), ZipFixtures.songCRC)
    }

    func testMXLContainerPathResolution() throws {
        let container = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container><rootfiles><rootfile full-path="./My%20Song.MusicXML"/></rootfiles></container>
        """.utf8)
        let zip = TestZip.build([("META-INF/container.xml", container), ("decoy.xml", Data("<x/>".utf8)),
                                 ("My Song.musicxml", Data(Self.xml.utf8))])
        let data = try MXLReader.musicXMLData(fromMXL: zip)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), Self.xml)
        XCTAssertEqual(MXLReader.rootfilePath(inContainer: container), "./My%20Song.MusicXML")
    }

    func testMXLWithoutAnyScoreThrows() {
        let zip = TestZip.build([("META-INF/container.xml", Data("<container/>".utf8)), ("readme.txt", Data("hi".utf8))])
        XCTAssertThrowsError(try MXLReader.musicXMLData(fromMXL: zip)) { XCTAssertEqual($0 as? MXLError, .noScoreFile) }
    }
}
