import Foundation

/// Errors thrown by `MXLReader` (ZIP-level problems are reported as `ZipError`).
public enum MXLError: Error, Equatable {
    /// The archive contains no MusicXML score file.
    case noScoreFile
}

/// Extracts the MusicXML document from a compressed MusicXML (`.mxl`) archive.
public enum MXLReader {
    static let containerPath = "META-INF/container.xml"

    /// Returns the (uncompressed) MusicXML bytes of the archive's score.
    ///
    /// Uses the first `<rootfile full-path="…">` of `META-INF/container.xml`; when the container is
    /// missing, unreadable or points at a missing entry, falls back to the first `.xml`/`.musicxml`
    /// entry outside `META-INF/`.
    public static func musicXMLData(fromMXL data: Data) throws -> Data {
        let archive = try ZipArchive(data: data)
        let names = archive.entryNames

        if let containerName = names.first(where: { $0 == containerPath })
            ?? names.first(where: { $0.caseInsensitiveCompare(containerPath) == .orderedSame }),
           let container = try? archive.data(forEntry: containerName),
           let path = rootfilePath(inContainer: container),
           let entry = resolve(path, in: names) {
            return try archive.data(forEntry: entry)
        }

        guard let fallback = names.first(where: isCandidateScore) else { throw MXLError.noScoreFile }
        return try archive.data(forEntry: fallback)
    }

    /// `full-path` of the first `<rootfile>` in a container document.
    static func rootfilePath(inContainer data: Data) -> String? {
        guard let root = try? LiteXML.parse(XMLTextEncoding.parserReadyData(data)) else { return nil }
        let rootfile = root.firstDescendant { $0.name == "rootfile" && $0.attribute("full-path") != nil }
        return rootfile?.attribute("full-path")?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Matches a container path to an archive entry: exact, then without "./" or "/", percent-decoded,
    /// and finally case-insensitively.
    static func resolve(_ path: String, in names: [String]) -> String? {
        var candidates = [path]
        var trimmed = path
        while trimmed.hasPrefix("./") { trimmed.removeFirst(2) }
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        candidates.append(trimmed)
        if let decoded = trimmed.removingPercentEncoding { candidates.append(decoded) }
        for c in candidates where names.contains(c) { return c }
        for c in candidates {
            if let match = names.first(where: { $0.caseInsensitiveCompare(c) == .orderedSame }) { return match }
        }
        return nil
    }

    private static func isCandidateScore(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".xml") || lower.hasSuffix(".musicxml") else { return false }
        return !lower.hasPrefix("meta-inf/") && !lower.hasPrefix("__macosx/")
    }
}
