import XCTest
@testable import PianoCoachCore

final class PieceLibraryStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PieceLibraryStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeStore() throws -> PieceLibraryStore {
        try PieceLibraryStore(rootDirectory: root)
    }

    private func samplePiece(title: String = "Minuet in G") -> Piece {
        Piece(title: title, videoID: "dQw4w9WgXcQ",
              createdAt: Date(timeIntervalSince1970: 1_700_000_000),
              lastPracticedAt: Date(timeIntervalSince1970: 1_700_086_400),
              videoBPM: 96,
              syncMap: SyncMap(bpm: 96, offset: 1.5, anchors: [SyncAnchor(videoTime: 10, beat: 16)]),
              loop: LoopRange(start: 12, end: 20), preferredMode: .followMe, resumeTime: 33.5, manualRate: 0.75)
    }

    private func fileNames(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    // MARK: - Init

    func testInitCreatesDirectories() throws {
        let store = try makeStore()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Attachments").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Tracks").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertEqual(store.libraryFileURL.lastPathComponent, "library.json")
        // Re-opening an existing library is fine.
        XCTAssertNoThrow(try makeStore())
    }

    // MARK: - Pieces

    func testLoadMissingLibraryIsEmpty() throws {
        XCTAssertEqual(try makeStore().loadPieces(), [])
    }

    func testSaveAndLoadRoundTrip() throws {
        let store = try makeStore()
        var second = samplePiece(title: "Für Elise")
        second.id = UUID()
        second.sheet = SheetAttachment(fileName: "A.musicxml", kind: .musicXML, originalName: "fur elise.musicxml")
        second.lastPracticedAt = nil
        let pieces = [samplePiece(), second]
        try store.savePieces(pieces)
        XCTAssertEqual(store.loadPieces(), pieces)
        // A second store on the same folder sees the same data.
        XCTAssertEqual(try makeStore().loadPieces(), pieces)
    }

    func testSavedJSONFormat() throws {
        let store = try makeStore()
        try store.savePieces([samplePiece()])
        let text = try String(contentsOf: store.libraryFileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"createdAt\" : \"2023-11-14T22:13:20Z\""), text)
        XCTAssertTrue(text.contains("\n"), "pretty printed")
        // Sorted keys: "createdAt" comes before "videoID".
        let created = try XCTUnwrap(text.range(of: "\"createdAt\""))
        let video = try XCTUnwrap(text.range(of: "\"videoID\""))
        XCTAssertLessThan(created.lowerBound, video.lowerBound)
    }

    func testSaveOverwrites() throws {
        let store = try makeStore()
        try store.savePieces([samplePiece(), samplePiece(title: "Two")])
        try store.savePieces([])
        XCTAssertEqual(store.loadPieces(), [])
    }

    func testCorruptLibraryIsMovedAside() throws {
        let store = try makeStore()
        try Data("{ not json".utf8).write(to: store.libraryFileURL)
        XCTAssertEqual(store.loadPieces(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.libraryFileURL.path))
        let corrupt = try fileNames(in: root).filter { $0.hasPrefix("library.corrupt-") && $0.hasSuffix(".json") }
        XCTAssertEqual(corrupt.count, 1)
        let moved = try Data(contentsOf: root.appendingPathComponent(corrupt[0]))
        XCTAssertEqual(String(decoding: moved, as: UTF8.self), "{ not json")

        // A second corrupt file in the same second gets its own name.
        try Data("[1, 2".utf8).write(to: store.libraryFileURL)
        XCTAssertEqual(store.loadPieces(), [])
        XCTAssertEqual(try fileNames(in: root).filter { $0.hasPrefix("library.corrupt-") }.count, 2)

        // The library keeps working afterwards.
        let piece = samplePiece()
        try store.savePieces([piece])
        XCTAssertEqual(store.loadPieces(), [piece])
    }

    func testEmptyFileCountsAsCorrupt() throws {
        let store = try makeStore()
        try Data().write(to: store.libraryFileURL)
        XCTAssertEqual(store.loadPieces(), [])
        XCTAssertEqual(try fileNames(in: root).filter { $0.hasPrefix("library.corrupt-") }.count, 1)
    }

    // MARK: - Attachments

    func testImportAttachmentFromURL() throws {
        let store = try makeStore()
        let sourceDir = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let source = sourceDir.appendingPathComponent("Minuet in G.MusicXML")
        let content = Data("<score-partwise/>".utf8)
        try content.write(to: source)

        let attachment = try store.importAttachment(from: source)
        XCTAssertEqual(attachment.kind, .musicXML)
        XCTAssertEqual(attachment.originalName, "Minuet in G.MusicXML")
        XCTAssertTrue(attachment.fileName.hasSuffix(".musicxml"))
        XCTAssertNotNil(UUID(uuidString: String(attachment.fileName.dropLast(".musicxml".count))))
        XCTAssertEqual(store.url(for: attachment).deletingLastPathComponent().standardizedFileURL.path,
                       store.attachmentsDirectory.standardizedFileURL.path)
        XCTAssertEqual(try store.data(for: attachment), content)
        // The source is copied, not moved.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        // Importing the same file twice gives two independent copies.
        let again = try store.importAttachment(from: source)
        XCTAssertNotEqual(again.fileName, attachment.fileName)
        XCTAssertEqual(try fileNames(in: store.attachmentsDirectory).count, 2)
    }

    func testImportAttachmentKinds() throws {
        let store = try makeStore()
        let cases: [(String, SheetKind)] = [("pdf", .pdf), ("mxl", .compressedMusicXML), ("mid", .midi),
                                            ("MIDI", .midi), ("png", .image), (".jpg", .image), ("xml", .musicXML)]
        for (ext, kind) in cases {
            let a = try store.importAttachment(data: Data([1, 2, 3]), fileExtension: ext, originalName: "file.\(ext)")
            XCTAssertEqual(a.kind, kind, ext)
            XCTAssertEqual(a.originalName, "file.\(ext)")
            XCTAssertFalse(a.fileName.contains(".."), a.fileName)
            XCTAssertTrue(a.fileName.hasSuffix("." + ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))))
            XCTAssertEqual(try store.data(for: a), Data([1, 2, 3]))
        }
    }

    func testUnsupportedFileType() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.importAttachment(data: Data(), fileExtension: "docx", originalName: "a.docx")) { error in
            XCTAssertEqual(error as? PieceLibraryError, .unsupportedFileType("docx"))
        }
        let source = root.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: source)
        XCTAssertThrowsError(try store.importAttachment(from: source)) { error in
            XCTAssertEqual(error as? PieceLibraryError, .unsupportedFileType("txt"))
        }
        let noExtension = root.appendingPathComponent("README")
        try Data("hi".utf8).write(to: noExtension)
        XCTAssertThrowsError(try store.importAttachment(from: noExtension)) { error in
            XCTAssertEqual(error as? PieceLibraryError, .unsupportedFileType(""))
        }
        XCTAssertEqual(try fileNames(in: store.attachmentsDirectory), [])
    }

    func testImportMissingSourceThrows() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.importAttachment(from: root.appendingPathComponent("missing.pdf")))
    }

    func testRemoveAttachment() throws {
        let store = try makeStore()
        let a = try store.importAttachment(data: Data([9]), fileExtension: "pdf", originalName: "a.pdf")
        store.removeAttachment(a)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: a).path))
        XCTAssertThrowsError(try store.data(for: a)) { error in
            XCTAssertEqual(error as? PieceLibraryError, .attachmentNotFound(a.fileName))
        }
        // Removing again is harmless.
        store.removeAttachment(a)
    }

    func testAttachmentURLStaysInsideAttachmentsFolder() throws {
        let store = try makeStore()
        let evil = SheetAttachment(fileName: "../library.json", kind: .pdf, originalName: "x")
        XCTAssertEqual(store.url(for: evil).deletingLastPathComponent().standardizedFileURL.path,
                       store.attachmentsDirectory.standardizedFileURL.path)
        let dots = SheetAttachment(fileName: "..", kind: .pdf, originalName: "x")
        XCTAssertEqual(store.url(for: dots).deletingLastPathComponent().standardizedFileURL.path,
                       store.attachmentsDirectory.standardizedFileURL.path)
    }

    // MARK: - Tracks

    private func sampleTrack() -> FollowTrack {
        var raw = [Float](repeating: 0, count: FeatureVector.semitoneCount)
        raw[39] = 1   // middle C
        let features = FeatureVector(semitones: raw)
        let events = (0..<5).map { i in
            TrackEvent(index: i, videoTime: Double(i) * 0.5, beat: Double(i), sourceMeasureIndex: i / 4,
                       beatInMeasure: Double(i % 4), pitches: [60], features: features, strength: 1)
        }
        return FollowTrack(origin: .score, events: events)
    }

    func testTrackRoundTrip() throws {
        let store = try makeStore()
        let id = UUID()
        XCTAssertNil(store.loadTrack(forPiece: id))
        let track = sampleTrack()
        try store.saveTrack(track, forPiece: id)
        XCTAssertEqual(store.loadTrack(forPiece: id), track)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.tracksDirectory.appendingPathComponent("\(id.uuidString).json").path))

        // Learned tracks with arbitrary feature values survive too.
        let learned = FollowTrack(origin: .learnedFromVideo, events: [
            TrackEvent(index: 0, videoTime: 1.25, features: .template(forPitches: [60, 64, 67]), strength: 0.8),
        ])
        try store.saveTrack(learned, forPiece: id)
        let loaded = try XCTUnwrap(store.loadTrack(forPiece: id))
        XCTAssertEqual(loaded.origin, .learnedFromVideo)
        XCTAssertEqual(loaded.events.count, 1)
        XCTAssertEqual(loaded.events[0].features.similarity(to: learned.events[0].features), 1, accuracy: 1e-5)

        store.removeTrack(forPiece: id)
        XCTAssertNil(store.loadTrack(forPiece: id))
        store.removeTrack(forPiece: id)
    }

    func testCorruptTrackLoadsAsNil() throws {
        let store = try makeStore()
        let id = UUID()
        try Data("garbage".utf8).write(to: store.tracksDirectory.appendingPathComponent("\(id.uuidString).json"))
        XCTAssertNil(store.loadTrack(forPiece: id))
    }

    // MARK: - Removing a piece

    func testRemoveFilesForPiece() throws {
        let store = try makeStore()
        var piece = samplePiece()
        piece.sheet = try store.importAttachment(data: Data([1]), fileExtension: "mid", originalName: "song.mid")
        piece.displaySheet = try store.importAttachment(data: Data([2]), fileExtension: "pdf", originalName: "song.pdf")
        try store.saveTrack(sampleTrack(), forPiece: piece.id)

        var other = samplePiece(title: "Other")
        other.id = UUID()
        other.sheet = try store.importAttachment(data: Data([3]), fileExtension: "png", originalName: "p.png")
        try store.saveTrack(sampleTrack(), forPiece: other.id)

        store.removeFiles(for: piece)
        XCTAssertEqual(try fileNames(in: store.attachmentsDirectory), [other.sheet!.fileName])
        XCTAssertEqual(try fileNames(in: store.tracksDirectory), ["\(other.id.uuidString).json"])
        XCTAssertNil(store.loadTrack(forPiece: piece.id))
        XCTAssertNotNil(store.loadTrack(forPiece: other.id))
    }

    // MARK: - Concurrency

    func testConcurrentAccess() throws {
        let store = try makeStore()
        let piece = samplePiece()
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            if i % 2 == 0 {
                try? store.savePieces([piece])
            } else {
                let loaded = store.loadPieces()
                XCTAssertTrue(loaded.isEmpty || loaded == [piece])
            }
            _ = try? store.importAttachment(data: Data([UInt8(i)]), fileExtension: "pdf", originalName: "\(i).pdf")
        }
        XCTAssertEqual(store.loadPieces(), [piece])
        XCTAssertEqual(try fileNames(in: store.attachmentsDirectory).count, 40)
        XCTAssertEqual(try fileNames(in: root).filter { $0.hasPrefix("library.corrupt-") }, [])
    }
}
