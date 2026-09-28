import Foundation

/// Errors thrown by `PieceLibraryStore`.
public enum PieceLibraryError: Error, Equatable, Sendable {
    /// The file extension (given without the dot, possibly empty) is not a supported sheet-music type.
    case unsupportedFileType(String)
    /// The attachment's file is missing from the library folder.
    case attachmentNotFound(String)
}

/// File-backed persistence for the piece library.
///
/// Layout under `rootDirectory`:
/// * `library.json` — the `[Piece]` list (pretty-printed, sorted keys, ISO-8601 dates),
/// * `Attachments/<UUID>.<ext>` — imported sheet-music files,
/// * `Tracks/<piece id>.json` — learned or score-derived `FollowTrack`s.
///
/// All methods are thread-safe (serialised with an internal lock).
/// Note: ISO-8601 dates are stored with whole-second precision.
public final class PieceLibraryStore: @unchecked Sendable {
    public let rootDirectory: URL
    public let attachmentsDirectory: URL
    public let tracksDirectory: URL
    public var libraryFileURL: URL { rootDirectory.appendingPathComponent("library.json") }

    private let lock = NSLock()

    /// Creates the store, creating `rootDirectory`, `Attachments` and `Tracks` if needed.
    public init(rootDirectory: URL) throws {
        self.rootDirectory = rootDirectory
        self.attachmentsDirectory = rootDirectory.appendingPathComponent("Attachments", isDirectory: true)
        self.tracksDirectory = rootDirectory.appendingPathComponent("Tracks", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: tracksDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Pieces

    /// The saved pieces. A missing file gives `[]`; an unreadable (corrupt) file is moved aside to
    /// `library.corrupt-<timestamp>.json` and `[]` is returned.
    public func loadPieces() -> [Piece] {
        locked {
            let url = libraryFileURL
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else { return [] }
            do {
                return try Self.makeDecoder().decode([Piece].self, from: data)
            } catch {
                moveAsideCorruptLibrary()
                return []
            }
        }
    }

    /// Atomically replaces `library.json` with `pieces`.
    public func savePieces(_ pieces: [Piece]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(pieces)
        try locked {
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            try data.write(to: libraryFileURL, options: .atomic)
        }
    }

    // MARK: - Attachments

    /// Copies a sheet-music file into `Attachments/<UUID>.<ext>`.
    ///
    /// On Apple platforms security-scoped access is started (and stopped) around the copy, so URLs from a
    /// document picker can be passed directly.
    /// - Throws: `PieceLibraryError.unsupportedFileType` for an unknown extension, or the copy error.
    public func importAttachment(from sourceURL: URL) throws -> SheetAttachment {
        let ext = sourceURL.pathExtension
        guard let kind = SheetKind(fileExtension: ext) else { throw PieceLibraryError.unsupportedFileType(ext) }
        let fileName = UUID().uuidString + "." + ext.lowercased()
        #if canImport(Darwin)
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        #endif
        try locked {
            try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: attachmentsDirectory.appendingPathComponent(fileName))
        }
        return SheetAttachment(fileName: fileName, kind: kind, originalName: sourceURL.lastPathComponent)
    }

    /// Writes `data` into `Attachments/<UUID>.<ext>`. `fileExtension` may include a leading dot.
    /// - Throws: `PieceLibraryError.unsupportedFileType` for an unknown extension, or the write error.
    public func importAttachment(data: Data, fileExtension: String, originalName: String) throws -> SheetAttachment {
        var ext = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        while ext.hasPrefix(".") { ext.removeFirst() }
        guard let kind = SheetKind(fileExtension: ext) else { throw PieceLibraryError.unsupportedFileType(ext) }
        let fileName = UUID().uuidString + "." + ext.lowercased()
        try locked {
            try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
            try data.write(to: attachmentsDirectory.appendingPathComponent(fileName), options: .atomic)
        }
        return SheetAttachment(fileName: fileName, kind: kind, originalName: originalName)
    }

    /// Location of the attachment's file (inside `Attachments`, whatever path the stored name contains).
    public func url(for attachment: SheetAttachment) -> URL {
        attachmentsDirectory.appendingPathComponent(Self.safeFileName(attachment.fileName))
    }

    /// Contents of the attachment's file.
    /// - Throws: `PieceLibraryError.attachmentNotFound` if the file is missing, or the read error.
    public func data(for attachment: SheetAttachment) throws -> Data {
        let fileURL = self.url(for: attachment)
        return try locked {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw PieceLibraryError.attachmentNotFound(attachment.fileName)
            }
            return try Data(contentsOf: fileURL)
        }
    }

    /// Deletes the attachment's file (no error if it is already gone).
    public func removeAttachment(_ attachment: SheetAttachment) {
        locked { removeAttachmentUnlocked(attachment) }
    }

    // MARK: - Tracks

    /// Atomically writes the piece's follow track to `Tracks/<id>.json`.
    public func saveTrack(_ track: FollowTrack, forPiece id: UUID) throws {
        let data = try JSONEncoder().encode(track)
        try locked {
            try FileManager.default.createDirectory(at: tracksDirectory, withIntermediateDirectories: true)
            try data.write(to: trackURL(forPiece: id), options: .atomic)
        }
    }

    /// The piece's follow track, or nil if missing or unreadable.
    public func loadTrack(forPiece id: UUID) -> FollowTrack? {
        locked {
            guard let data = try? Data(contentsOf: trackURL(forPiece: id)) else { return nil }
            return try? JSONDecoder().decode(FollowTrack.self, from: data)
        }
    }

    /// Deletes the piece's follow track (no error if there is none).
    public func removeTrack(forPiece id: UUID) {
        locked { removeTrackUnlocked(forPiece: id) }
    }

    /// Deletes every file belonging to `piece`: its sheet, display sheet and follow track.
    public func removeFiles(for piece: Piece) {
        locked {
            if let sheet = piece.sheet { removeAttachmentUnlocked(sheet) }
            if let display = piece.displaySheet { removeAttachmentUnlocked(display) }
            removeTrackUnlocked(forPiece: piece.id)
        }
    }

    // MARK: - Private

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func trackURL(forPiece id: UUID) -> URL {
        tracksDirectory.appendingPathComponent(id.uuidString + ".json")
    }

    private func removeAttachmentUnlocked(_ attachment: SheetAttachment) {
        try? FileManager.default.removeItem(at: url(for: attachment))
    }

    private func removeTrackUnlocked(forPiece id: UUID) {
        try? FileManager.default.removeItem(at: trackURL(forPiece: id))
    }

    /// Moves `library.json` to `library.corrupt-<timestamp>[-n].json`.
    private func moveAsideCorruptLibrary() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: Date())
        let fm = FileManager.default
        var destination = rootDirectory.appendingPathComponent("library.corrupt-\(stamp).json")
        var n = 2
        while fm.fileExists(atPath: destination.path) {
            destination = rootDirectory.appendingPathComponent("library.corrupt-\(stamp)-\(n).json")
            n += 1
        }
        try? fm.moveItem(at: libraryFileURL, to: destination)
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The last path component of a stored file name, never "", "." or "..".
    private static func safeFileName(_ name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? ""
        return (last.isEmpty || last == "." || last == "..") ? "_invalid_" : last
    }
}
