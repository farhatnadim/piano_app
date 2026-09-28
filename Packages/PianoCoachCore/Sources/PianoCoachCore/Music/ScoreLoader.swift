import Foundation

/// Errors thrown by `ScoreLoader`.
public enum ScoreLoaderError: Error, Equatable {
    /// The sheet kind (PDF, image) carries no notes.
    case notAScore(SheetKind)
    /// The MusicXML bytes could not be decoded as text.
    case unreadableText
}

/// Entry point for turning an attached sheet-music file into something the app can use.
public enum ScoreLoader {
    /// Parses a MusicXML, compressed MusicXML or MIDI file into a `Score` (repeats unrolled).
    ///
    /// Plain and compressed MusicXML are recognised by content as well, so a zipped file with a `.xml`
    /// extension (or vice versa) still loads. PDF and image kinds throw `ScoreLoaderError.notAScore`.
    public static func loadScore(from data: Data, kind: SheetKind) throws -> Score {
        switch kind {
        case .musicXML, .compressedMusicXML:
            return try MusicXMLParser.parse(data: try musicXMLData(from: data))
        case .midi:
            return try MIDIFileParser.parse(data: data)
        case .pdf, .image:
            throw ScoreLoaderError.notAScore(kind)
        }
    }

    /// The MusicXML document as text for the sheet-music display (unzipped for `.mxl`),
    /// or nil for kinds that are not MusicXML (MIDI, PDF, image).
    public static func musicXMLText(from data: Data, kind: SheetKind) throws -> String? {
        switch kind {
        case .musicXML, .compressedMusicXML:
            guard let text = XMLTextEncoding.decode(try musicXMLData(from: data)) else {
                throw ScoreLoaderError.unreadableText
            }
            return text
        case .midi, .pdf, .image:
            return nil
        }
    }

    /// Raw MusicXML bytes: unzipped when the data is a ZIP archive, as-is otherwise.
    static func musicXMLData(from data: Data) throws -> Data {
        isZip(data) ? try MXLReader.musicXMLData(fromMXL: data) : data
    }

    static func isZip(_ data: Data) -> Bool {
        data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04]) || data.prefix(4).elementsEqual([0x50, 0x4B, 0x05, 0x06])
    }
}
