import Foundation

/// Errors thrown while reading a ZIP archive.
public enum ZipError: Error, Equatable {
    /// No End Of Central Directory record was found.
    case notAZipArchive
    /// A structure in the archive is inconsistent or points outside the file.
    case corrupted(String)
    /// The archive (or an entry) needs Zip64 extensions, which are not supported.
    case zip64NotSupported
    /// The entry is encrypted.
    case encryptedEntry(String)
    /// The entry uses a compression method other than stored (0) or deflate (8).
    case unsupportedCompressionMethod(method: Int, entry: String)
    /// No entry with that name exists.
    case entryNotFound(String)
    /// The entry's data failed to decompress.
    case decompressionFailed(entry: String, reason: String)
    /// The decompressed data does not match the recorded CRC-32 or size.
    case checksumMismatch(String)
}

/// Minimal read-only ZIP archive reader (enough for `.mxl` compressed MusicXML).
///
/// Entries are located through the central directory, whose sizes are authoritative (local headers
/// written with general-purpose flag bit 3 leave their sizes zero and append a data descriptor).
/// Supports stored (0) and deflate (8) entries; Zip64, encryption and multi-disk archives are rejected.
public struct ZipArchive: Sendable {
    struct Entry: Sendable {
        var name: String
        var flags: Int
        var method: Int
        var crc32: UInt32
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    private let bytes: [UInt8]
    private let entries: [Entry]
    private let entryIndex: [String: Int]

    static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    static let centralDirectorySignature: UInt32 = 0x0201_4B50
    static let localHeaderSignature: UInt32 = 0x0403_4B50

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        self.bytes = bytes
        let eocd = try ZipArchive.findEndOfCentralDirectory(bytes)

        let totalEntries = ZipArchive.u16(bytes, eocd + 10)
        let directorySize = Int(ZipArchive.u32(bytes, eocd + 12))
        let directoryOffset = Int(ZipArchive.u32(bytes, eocd + 16))
        if totalEntries == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            throw ZipError.zip64NotSupported
        }
        if eocd >= 20, ZipArchive.u32(bytes, eocd - 20) == ZipArchive.zip64LocatorSignature {
            throw ZipError.zip64NotSupported
        }
        guard directoryOffset + directorySize <= eocd else {
            throw ZipError.corrupted("central directory lies outside the archive")
        }

        var entries: [Entry] = []
        var index: [String: Int] = [:]
        var p = directoryOffset
        for _ in 0..<totalEntries {
            guard p + 46 <= bytes.count, ZipArchive.u32(bytes, p) == ZipArchive.centralDirectorySignature else {
                throw ZipError.corrupted("bad central directory entry at offset \(p)")
            }
            let flags = ZipArchive.u16(bytes, p + 8)
            let method = ZipArchive.u16(bytes, p + 10)
            let crc = ZipArchive.u32(bytes, p + 16)
            let compressed = ZipArchive.u32(bytes, p + 20)
            let uncompressed = ZipArchive.u32(bytes, p + 24)
            let nameLength = ZipArchive.u16(bytes, p + 28)
            let extraLength = ZipArchive.u16(bytes, p + 30)
            let commentLength = ZipArchive.u16(bytes, p + 32)
            let localOffset = ZipArchive.u32(bytes, p + 42)
            let nameStart = p + 46
            guard nameStart + nameLength + extraLength + commentLength <= bytes.count else {
                throw ZipError.corrupted("central directory entry overruns the archive")
            }
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw ZipError.zip64NotSupported
            }
            let name = ZipArchive.decodeName(bytes[nameStart..<(nameStart + nameLength)])
            if index[name] == nil { index[name] = entries.count }
            entries.append(Entry(name: name, flags: flags, method: method, crc32: crc,
                                 compressedSize: Int(compressed), uncompressedSize: Int(uncompressed),
                                 localHeaderOffset: Int(localOffset)))
            p = nameStart + nameLength + extraLength + commentLength
        }
        self.entries = entries
        self.entryIndex = index
    }

    /// Names of all entries (including directories, which end in "/"), in central-directory order.
    public var entryNames: [String] { entries.map(\.name) }

    /// Decompressed contents of the entry called `name` (exact match), CRC-checked.
    public func data(forEntry name: String) throws -> Data {
        guard let i = entryIndex[name] else { throw ZipError.entryNotFound(name) }
        let entry = entries[i]
        if entry.flags & 0x1 != 0 { throw ZipError.encryptedEntry(name) }
        guard entry.method == 0 || entry.method == 8 else {
            throw ZipError.unsupportedCompressionMethod(method: entry.method, entry: name)
        }

        let h = entry.localHeaderOffset
        guard h + 30 <= bytes.count, ZipArchive.u32(bytes, h) == ZipArchive.localHeaderSignature else {
            throw ZipError.corrupted("bad local header for \(name)")
        }
        // Only the local name/extra lengths are used: its sizes may be zero (data descriptor).
        let start = h + 30 + ZipArchive.u16(bytes, h + 26) + ZipArchive.u16(bytes, h + 28)
        let end = start + entry.compressedSize
        guard end <= bytes.count else { throw ZipError.corrupted("data for \(name) overruns the archive") }

        let result: Data
        if entry.method == 0 {
            guard entry.compressedSize == entry.uncompressedSize else {
                throw ZipError.corrupted("stored entry \(name) has mismatched sizes")
            }
            result = Data(bytes[start..<end])
        } else {
            do {
                result = try Inflate.inflate(Data(bytes[start..<end]), sizeHint: entry.uncompressedSize,
                                             limit: entry.uncompressedSize)
            } catch let InflateError.invalidData(reason) {
                throw ZipError.decompressionFailed(entry: name, reason: reason)
            }
        }
        guard result.count == entry.uncompressedSize else {
            throw ZipError.checksumMismatch("\(name): expected \(entry.uncompressedSize) bytes, got \(result.count)")
        }
        guard CRC32.checksum(result) == entry.crc32 else {
            throw ZipError.checksumMismatch("\(name): CRC-32 mismatch")
        }
        return result
    }

    // MARK: - Helpers

    /// Scans backwards (at most 65535 bytes of comment + 22 bytes of record) for the EOCD signature.
    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) throws -> Int {
        guard bytes.count >= 22 else { throw ZipError.notAZipArchive }
        let lowest = max(0, bytes.count - 65_557)
        var p = bytes.count - 22
        var fallback: Int?
        while p >= lowest {
            if u32(bytes, p) == endOfCentralDirectorySignature {
                let commentLength = u16(bytes, p + 20)
                if p + 22 + commentLength == bytes.count { return p }
                if fallback == nil, p + 22 + commentLength <= bytes.count { fallback = p }
            }
            p -= 1
        }
        if let fallback = fallback { return fallback }
        throw ZipError.notAZipArchive
    }

    private static func decodeName(_ raw: ArraySlice<UInt8>) -> String {
        // Names are UTF-8 when flag bit 11 is set, and in practice almost always valid UTF-8 anyway.
        if let s = String(bytes: raw, encoding: .utf8) { return s }
        // Legacy archives use code page 437; Latin-1 keeps ASCII names intact and never fails.
        return String(bytes: raw, encoding: .isoLatin1) ?? String(decoding: raw, as: UTF8.self)
    }

    @inline(__always)
    static func u16(_ b: [UInt8], _ p: Int) -> Int {
        Int(b[p]) | Int(b[p + 1]) << 8
    }

    @inline(__always)
    static func u32(_ b: [UInt8], _ p: Int) -> UInt32 {
        UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
    }
}
