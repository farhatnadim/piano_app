import XCTest
@testable import PianoCoachCore

final class ZipArchiveTests: XCTestCase {
    // MARK: - Python-generated archives

    func testHandmadeArchiveListsEntriesInCentralDirectoryOrder() throws {
        let zip = try ZipArchive(data: ZipFixtures.data(ZipFixtures.handmadeZip))
        XCTAssertEqual(zip.entryNames, ["mimetype", "META-INF/", "META-INF/container.xml", "scores/song.musicxml"])
    }

    func testReadsStoredEntryAndDirectory() throws {
        let zip = try ZipArchive(data: ZipFixtures.data(ZipFixtures.handmadeZip))
        XCTAssertEqual(String(decoding: try zip.data(forEntry: "mimetype"), as: UTF8.self),
                       "application/vnd.recordare.musicxml")
        XCTAssertEqual(try zip.data(forEntry: "META-INF/"), Data())
    }

    func testReadsDeflatedEntryWhoseLocalHeaderHasAnExtraField() throws {
        let zip = try ZipArchive(data: ZipFixtures.data(ZipFixtures.handmadeZip))
        let container = String(decoding: try zip.data(forEntry: "META-INF/container.xml"), as: UTF8.self)
        XCTAssertTrue(container.hasPrefix("<?xml"))
        XCTAssertTrue(container.contains(#"full-path="scores/song.musicxml""#))
    }

    func testReadsEntryWithDataDescriptorUsingCentralDirectorySizes() throws {
        // Flag bit 3: the local header's CRC and sizes are zero; the real values follow the data.
        let zip = try ZipArchive(data: ZipFixtures.data(ZipFixtures.handmadeZip))
        let song = try zip.data(forEntry: "scores/song.musicxml")
        XCTAssertEqual(song.count, ZipFixtures.songLength)
        XCTAssertEqual(CRC32.checksum(song), ZipFixtures.songCRC)
        XCTAssertTrue(String(decoding: song, as: UTF8.self).contains("<work-title>Zipped Song</work-title>"))
    }

    func testReadsArchiveStreamedByPythonZipfile() throws {
        // Every entry written to a non-seekable stream uses a data descriptor.
        let zip = try ZipArchive(data: ZipFixtures.data(ZipFixtures.streamedMXL))
        XCTAssertEqual(zip.entryNames, ["mimetype", "META-INF/container.xml", "scores/song.musicxml"])
        XCTAssertEqual(CRC32.checksum(try zip.data(forEntry: "scores/song.musicxml")), ZipFixtures.songCRC)
        XCTAssertEqual(String(decoding: try zip.data(forEntry: "mimetype"), as: UTF8.self),
                       "application/vnd.recordare.musicxml")
    }

    func testMissingEntry() throws {
        let zip = try ZipArchive(data: ZipFixtures.data(ZipFixtures.handmadeZip))
        XCTAssertThrowsError(try zip.data(forEntry: "Scores/Song.musicxml")) { error in
            XCTAssertEqual(error as? ZipError, .entryNotFound("Scores/Song.musicxml"))
        }
    }

    // MARK: - Archives built in the test

    func testRoundTripOfSwiftBuiltArchiveWithComment() throws {
        let files: [(String, Data)] = [("a.txt", Data("alpha".utf8)), ("dir/b.txt", Data("beta".utf8)), ("empty", Data())]
        // A comment that itself contains an EOCD signature must not confuse the backwards scan.
        let comment = Data([0x50, 0x4B, 0x05, 0x06]) + Data(repeating: 0x20, count: 500)
        let zip = try ZipArchive(data: TestZip.build(files, comment: comment))
        XCTAssertEqual(zip.entryNames, ["a.txt", "dir/b.txt", "empty"])
        XCTAssertEqual(try zip.data(forEntry: "dir/b.txt"), Data("beta".utf8))
        XCTAssertEqual(try zip.data(forEntry: "empty"), Data())
    }

    func testUTF8EntryNames() throws {
        let zip = try ZipArchive(data: TestZip.build([("Für Elise – Beethoven.musicxml", Data("x".utf8))]))
        XCTAssertEqual(zip.entryNames, ["Für Elise – Beethoven.musicxml"])
        XCTAssertEqual(try zip.data(forEntry: "Für Elise – Beethoven.musicxml"), Data("x".utf8))
    }

    func testRejectsDataThatIsNotAZip() {
        for bytes in [Data(), Data("PK".utf8), Data(repeating: 0x41, count: 4096)] {
            XCTAssertThrowsError(try ZipArchive(data: bytes)) { XCTAssertEqual($0 as? ZipError, .notAZipArchive) }
        }
    }

    func testRejectsUnsupportedCompressionMethod() throws {
        var bytes = TestZip.build([("song.xml", Data("<a/>".utf8))])
        bytes[TestZip.centralDirectoryOffset(bytes) + 10] = 12  // bzip2
        let zip = try ZipArchive(data: bytes)
        XCTAssertThrowsError(try zip.data(forEntry: "song.xml")) {
            XCTAssertEqual($0 as? ZipError, .unsupportedCompressionMethod(method: 12, entry: "song.xml"))
        }
    }

    func testRejectsEncryptedEntry() throws {
        var bytes = TestZip.build([("secret.xml", Data("<a/>".utf8))])
        bytes[TestZip.centralDirectoryOffset(bytes) + 8] |= 0x01
        XCTAssertThrowsError(try ZipArchive(data: bytes).data(forEntry: "secret.xml")) {
            XCTAssertEqual($0 as? ZipError, .encryptedEntry("secret.xml"))
        }
    }

    func testDetectsCRCMismatch() throws {
        var bytes = TestZip.build([("song.xml", Data("<score/>".utf8))])
        bytes[30 + "song.xml".utf8.count] ^= 0x01  // flip a bit of the stored data
        XCTAssertThrowsError(try ZipArchive(data: bytes).data(forEntry: "song.xml")) { error in
            guard case ZipError.checksumMismatch = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testReportsCorruptDeflateData() throws {
        // Method 8 with bytes that are not a valid DEFLATE stream (block type 3).
        let bytes = TestZip.build([("bad.xml", Data([0xFF, 0xFF, 0xFF]))], method: 8, uncompressedSize: 10, crc: 0)
        XCTAssertThrowsError(try ZipArchive(data: bytes).data(forEntry: "bad.xml")) { error in
            guard case ZipError.decompressionFailed(entry: "bad.xml", _) = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testRejectsZip64() {
        var bytes = TestZip.build([("a", Data("a".utf8))])
        let eocd = bytes.count - 22
        bytes[eocd + 10] = 0xFF
        bytes[eocd + 11] = 0xFF
        XCTAssertThrowsError(try ZipArchive(data: bytes)) { XCTAssertEqual($0 as? ZipError, .zip64NotSupported) }

        var sizes = TestZip.build([("a", Data("a".utf8))])
        let cd = TestZip.centralDirectoryOffset(sizes)
        for k in 20..<24 { sizes[cd + k] = 0xFF }
        XCTAssertThrowsError(try ZipArchive(data: sizes)) { XCTAssertEqual($0 as? ZipError, .zip64NotSupported) }
    }

    func testRejectsDamagedCentralDirectory() {
        let bytes = TestZip.build([("a", Data("a".utf8))])
        var broken = bytes
        broken[TestZip.centralDirectoryOffset(bytes)] = 0x00  // destroy the central directory signature
        XCTAssertThrowsError(try ZipArchive(data: broken)) { error in
            guard case ZipError.corrupted = error else { return XCTFail("unexpected \(error)") }
        }
    }
}

// MARK: - Test helpers

/// Builds small ZIP archives (stored entries unless told otherwise) for error-path tests.
enum TestZip {
    static func build(_ files: [(String, Data)], comment: Data = Data(), method: UInt16 = 0,
                      uncompressedSize: Int? = nil, crc: UInt32? = nil) -> Data {
        var out = Data()
        var central = Data()
        for (name, data) in files {
            let nameBytes = Data(name.utf8)
            let checksum = crc ?? CRC32.checksum(data)
            let size = UInt32(uncompressedSize ?? data.count)
            let offset = UInt32(out.count)
            out += le32(0x0403_4B50) + le16(20) + le16(0x800) + le16(method) + le16(0) + le16(0)
            out += le32(checksum) + le32(UInt32(data.count)) + le32(size) + le16(UInt16(nameBytes.count)) + le16(0)
            out += nameBytes + data
            central += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0x800) + le16(method) + le16(0) + le16(0)
            central += le32(checksum) + le32(UInt32(data.count)) + le32(size) + le16(UInt16(nameBytes.count))
            central += le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + nameBytes
        }
        let directoryOffset = UInt32(out.count)
        out += central
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(UInt16(files.count)) + le16(UInt16(files.count))
        out += le32(UInt32(central.count)) + le32(directoryOffset) + le16(UInt16(comment.count)) + comment
        return out
    }

    /// Offset of the first central directory record (read from the EOCD of an archive without comment).
    static func centralDirectoryOffset(_ zip: Data) -> Int {
        let bytes = [UInt8](zip)
        var p = bytes.count - 22
        while !(bytes[p] == 0x50 && bytes[p + 1] == 0x4B && bytes[p + 2] == 0x05 && bytes[p + 3] == 0x06) { p -= 1 }
        return Int(bytes[p + 16]) | Int(bytes[p + 17]) << 8 | Int(bytes[p + 18]) << 16 | Int(bytes[p + 19]) << 24
    }

    private static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }
}

/// ZIP/MXL archives generated with Python (`struct` by hand, and `zipfile`).
///
/// * `handmadeZip`: "mimetype" (stored), "META-INF/" (directory), "META-INF/container.xml" (deflated,
///   local header carries an extra field the central directory lacks), "scores/song.musicxml"
///   (deflated with a data descriptor: zero CRC/sizes in its local header) and an archive comment.
/// * `streamedMXL`: the same three files written by `zipfile` to a non-seekable stream (all entries use
///   data descriptors).
/// * `noContainerMXL`: no container; "readme.txt", "META-INF/manifest.xml",
///   "__MACOSX/._piece.musicxml" and the score as "Piece.MusicXML".
/// * `brokenContainerMXL`: container.xml points at "missing.xml"; the score is "other/song.xml".
enum ZipFixtures {
    static let songLength = 898
    static let songCRC: UInt32 = 0x8E46_3B01

    static func data(_ base64: String) -> Data {
        Data(base64Encoded: base64, options: .ignoreUnknownCharacters)!
    }

    static let handmadeZip = """
    UEsDBBQAAAAAAAAAIQAuQhWCIgAAACIAAAAIAAAAbWltZXR5cGVhcHBsaWNhdGlvbi92bmQucmVjb3JkYXJlLm11c2ljeG1sUEsD
    BBQAAAAAAAAAIQAAAAAAAAAAAAAAAAAJAAAATUVUQS1JTkYvUEsDBBQAAAAIAAAAIQDMtQndmAAAAAsBAAAWAAkATUVUQS1JTkYv
    Y29udGFpbmVyLnhtbFVUBQABABBeX42PsQ7CMAxE935F5BW1gY0hKRtfAB8QJW6xlNpRklbw97QMqAsS48l3987m8pyiWjAXErZw
    6o6gkL0E4tHC/XZtz3DpG+OFqyPG3DdKmSxSB4pYNrXTaphjbJOrDwvFS8aii/DYTXMhv4JATRjItfWV0IJLKZJ3dSXrhUOXcY0E
    l/HrP2wZ/SckheF3/3b8FBm9G2/07q83UEsDBBQACAAIAAAAIQAAAAAAAAAAAAAAAAAUAAAAc2NvcmVzL3NvbmcubXVzaWN4bWy1
    kk1PwzAMhu/8ipB7ayZxQCgLEtuQkPioYEjALWusEbEmVeKu8O9J03YbSNzg0th+ncd2anHxUW3YFn0wzk75JD/hDG3ptLHrKX9a
    XmVnnAVSVquNszjl1vELeSSO5/ez5UuxYKF0HrNaeWpNQFY8Xd5czxjPAB4wSlp5BJgv5+y2CaZ8vr1hp/kJK4Z8gMUdZ/yNqD4H
    aNs2r7q02FPu/Bo06QAjO48ej6V/VNz1HrlRZky0zr/L9M3I0Ablq6lr1OzR2bWAg3jvpDsdLtuYQPKAz4ye8mLCZS9bVaEsjLJO
    wD4gYH9BDkICjdgdJQZiqEIVGo/MNtUKfXzyQYiSIvJm1RAGKbTZmm6uICcC9o4g09VcoaIgTwX0RvIz+qxxjPWOgD4dDshjMeso
    KrWh8i3OTFjLWRylO4UrSW0TarDiWH2ebryi2EhqarQFJNbv4Pl/gRf/Bb76A7CA4VenTUiLEbcXvq+vPPoCUEsHCAE7Ro5sAQAA
    ggMAAFBLAQIeAxQAAAAAAAAAIQAuQhWCIgAAACIAAAAIAAAAAAAAAAAAAAAAAAAAAABtaW1ldHlwZVBLAQIeAxQAAAAAAAAAIQAA
    AAAAAAAAAAAAAAAJAAAAAAAAAAAAAAAAAEgAAABNRVRBLUlORi9QSwECHgMUAAAACAAAACEAzLUJ3ZgAAAALAQAAFgAAAAAAAAAA
    AAAAAABvAAAATUVUQS1JTkYvY29udGFpbmVyLnhtbFBLAQIeAxQACAAIAAAAIQABO0aObAEAAIIDAAAUAAAAAAAAAAAAAAAAAEQB
    AABzY29yZXMvc29uZy5tdXNpY3htbFBLBQYAAAAABAAEAPMAAADyAgAAFwBQaWFub0NvYWNoIHRlc3QgYXJjaGl2ZQ==
    """
    static let streamedMXL = """
    UEsDBBQACAAAAAAAIQAAAAAAAAAAAAAAAAAIAAAAbWltZXR5cGVhcHBsaWNhdGlvbi92bmQucmVjb3JkYXJlLm11c2ljeG1sUEsH
    CC5CFYIiAAAAIgAAAFBLAwQUAAgACADsujxdAAAAAAAAAAAAAAAAFgAAAE1FVEEtSU5GL2NvbnRhaW5lci54bWyNj7EOwjAMRPd+
    ReQVtYGNISkbXwAfECVusZTaUZJW8Pe0DKgLEuPJd/fO5vKcolowFxK2cOqOoJC9BOLRwv12bc9w6Rvjhasjxtw3SpksUgeKWDa1
    02qYY2yTqw8LxUvGoovw2E1zIb+CQE0YyLX1ldCCSymSd3Ul64VDl3GNBJfx6z9sGf0nJIXhd/92/BQZvRtv9O6vN1BLBwjMtQnd
    mAAAAAsBAABQSwMEFAAIAAgA7Lo8XQAAAAAAAAAAAAAAABQAAABzY29yZXMvc29uZy5tdXNpY3htbLWSTU/DMAyG7/yKkHtrJnFA
    KAsS25CQ+KhgSMAta6wRsSZV4q7w70nTdhtI3ODS2H6dx3ZqcfFRbdgWfTDOTvkkP+EMbem0sespf1peZWecBVJWq42zOOXW8Qt5
    JI7n97PlS7FgoXQes1p5ak1AVjxd3lzPGM8AHjBKWnkEmC/n7LYJpny+vWGn+QkrhnyAxR1n/I2oPgdo2zavurTYU+78GjTpACM7
    jx6PpX9U3PUeuVFmTLTOv8v0zcjQBuWrqWvU7NHZtYCDeO+kOx0u25hA8oDPjJ7yYsJlL1tVoSyMsk7APiBgf0EOQgKN2B0lBmKo
    QhUaj8w21Qp9fPJBiJIi8mbVEAYptNmabq4gJwL2jiDT1VyhoiBPBfRG8jP6rHGM9Y6APh0OyGMx6ygqtaHyLc5MWMtZHKU7hStJ
    bRNqsOJYfZ5uvKLYSGpqtAUk1u/g+X+BF/8FvvoDsIDhV6dNSIsRtxe+r688+gJQSwcIATtGjmwBAACCAwAAUEsBAhQDFAAIAAAA
    AAAhAC5CFYIiAAAAIgAAAAgAAAAAAAAAAAAAAIABAAAAAG1pbWV0eXBlUEsBAhQDFAAIAAgA7Lo8Xcy1Cd2YAAAACwEAABYAAAAA
    AAAAAAAAAIABWAAAAE1FVEEtSU5GL2NvbnRhaW5lci54bWxQSwECFAMUAAgACADsujxdATtGjmwBAACCAwAAFAAAAAAAAAAAAAAA
    gAE0AQAAc2NvcmVzL3NvbmcubXVzaWN4bWxQSwUGAAAAAAMAAwC8AAAA4gIAAAAA
    """
    static let noContainerMXL = """
    UEsDBBQAAAAIAOy6PF1bztkkDwAAAA0AAAAKAAAAcmVhZG1lLnR4dMvLL1EoyUhVKE7OL0oFAFBLAwQUAAAACADsujxd7TfJiw0A
    AAALAAAAFQAAAE1FVEEtSU5GL21hbmlmZXN0LnhtbLPJTczLTEstLtG3AwBQSwMEFAAAAAgA7Lo8Xd6PSc8PAAAADQAAABkAAABf
    X01BQ09TWC8uX3BpZWNlLm11c2ljeG1sK0otzi8tSk5VSMsvygYAUEsDBBQAAAAIAOy6PF0BO0aObAEAAIIDAAAOAAAAUGllY2Uu
    TXVzaWNYTUy1kk1PwzAMhu/8ipB7ayZxQCgLEtuQkPioYEjALWusEbEmVeKu8O9J03YbSNzg0th+ncd2anHxUW3YFn0wzk75JD/h
    DG3ptLHrKX9aXmVnnAVSVquNszjl1vELeSSO5/ez5UuxYKF0HrNaeWpNQFY8Xd5czxjPAB4wSlp5BJgv5+y2CaZ8vr1hp/kJK4Z8
    gMUdZ/yNqD4HaNs2r7q02FPu/Bo06QAjO48ej6V/VNz1HrlRZky0zr/L9M3I0Ablq6lr1OzR2bWAg3jvpDsdLtuYQPKAz4ye8mLC
    ZS9bVaEsjLJOwD4gYH9BDkICjdgdJQZiqEIVGo/MNtUKfXzyQYiSIvJm1RAGKbTZmm6uICcC9o4g09VcoaIgTwX0RvIz+qxxjPWO
    gD4dDshjMesoKrWh8i3OTFjLWRylO4UrSW0TarDiWH2ebryi2EhqarQFJNbv4Pl/gRf/Bb76A7CA4VenTUiLEbcXvq+vPPoCUEsB
    AhQDFAAAAAgA7Lo8XVvO2SQPAAAADQAAAAoAAAAAAAAAAAAAAIABAAAAAHJlYWRtZS50eHRQSwECFAMUAAAACADsujxd7TfJiw0A
    AAALAAAAFQAAAAAAAAAAAAAAgAE3AAAATUVUQS1JTkYvbWFuaWZlc3QueG1sUEsBAhQDFAAAAAgA7Lo8Xd6PSc8PAAAADQAAABkA
    AAAAAAAAAAAAAIABdwAAAF9fTUFDT1NYLy5fcGllY2UubXVzaWN4bWxQSwECFAMUAAAACADsujxdATtGjmwBAACCAwAADgAAAAAA
    AAAAAAAAgAG9AAAAUGllY2UuTXVzaWNYTUxQSwUGAAAAAAQABAD+AAAAVQIAAAAA
    """
    static let brokenContainerMXL = """
    UEsDBBQAAAAIAOy6PF2FHkElmgAAAAIBAAAWAAAATUVUQS1JTkYvY29udGFpbmVyLnhtbH3POw7CMAwG4L2niLyiJrAxJGXjBHCA
    KHHBUl6K0wpuT8rUBcZftj/b+vKKQaxYmXIycJJHEJhc9pQeBu6363iGyzRol1OzlLBOgxC65txmCshb2mUxLyGMxbangUjMHZHd
    BxHRkx3bu6ABW0ogZ1tfqNbkZUWXq7cVZVyYXO8/bDPqj819Allx7n7x829/K34hrXY3a7V75wNQSwMEFAAAAAgA7Lo8XQE7Ro5s
    AQAAggMAAA4AAABvdGhlci9zb25nLnhtbLWSTU/DMAyG7/yKkHtrJnFAKAsS25CQ+KhgSMAta6wRsSZV4q7w70nTdhtI3ODS2H6d
    x3ZqcfFRbdgWfTDOTvkkP+EMbem0sespf1peZWecBVJWq42zOOXW8Qt5JI7n97PlS7FgoXQes1p5ak1AVjxd3lzPGM8AHjBKWnkE
    mC/n7LYJpny+vWGn+QkrhnyAxR1n/I2oPgdo2zavurTYU+78GjTpACM7jx6PpX9U3PUeuVFmTLTOv8v0zcjQBuWrqWvU7NHZtYCD
    eO+kOx0u25hA8oDPjJ7yYsJlL1tVoSyMsk7APiBgf0EOQgKN2B0lBmKoQhUaj8w21Qp9fPJBiJIi8mbVEAYptNmabq4gJwL2jiDT
    1VyhoiBPBfRG8jP6rHGM9Y6APh0OyGMx6ygqtaHyLc5MWMtZHKU7hStJbRNqsOJYfZ5uvKLYSGpqtAUk1u/g+X+BF/8FvvoDsIDh
    V6dNSIsRtxe+r688+gJQSwECFAMUAAAACADsujxdhR5BJZoAAAACAQAAFgAAAAAAAAAAAAAAgAEAAAAATUVUQS1JTkYvY29udGFp
    bmVyLnhtbFBLAQIUAxQAAAAIAOy6PF0BO0aObAEAAIIDAAAOAAAAAAAAAAAAAACAAc4AAABvdGhlci9zb25nLnhtbFBLBQYAAAAA
    AgACAIAAAABmAgAAAAA=
    """
}
