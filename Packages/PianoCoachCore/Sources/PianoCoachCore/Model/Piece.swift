import Foundation

/// Kind of sheet-music file attached to a piece.
public enum SheetKind: String, Codable, CaseIterable, Sendable {
    /// Uncompressed MusicXML (.musicxml / .xml) — displayed with a moving cursor and used for following.
    case musicXML
    /// Compressed MusicXML (.mxl) — same as `musicXML` once unzipped.
    case compressedMusicXML
    /// Standard MIDI file (.mid / .midi) — used for following; no sheet display.
    case midi
    /// PDF — display only.
    case pdf
    /// PNG/JPEG/HEIC scan or photo — display only.
    case image

    /// Infers the kind from a file extension (case-insensitive), or nil if unsupported.
    public init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "musicxml", "xml": self = .musicXML
        case "mxl": self = .compressedMusicXML
        case "mid", "midi", "smf": self = .midi
        case "pdf": self = .pdf
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff": self = .image
        default: return nil
        }
    }

    /// True if the file contains notes the coach can follow.
    public var hasNotes: Bool {
        switch self {
        case .musicXML, .compressedMusicXML, .midi: return true
        case .pdf, .image: return false
        }
    }

    /// True if the file can be shown as sheet music.
    public var isDisplayable: Bool { self != .midi }
}

/// A sheet-music file copied into the app's library folder.
public struct SheetAttachment: Codable, Hashable, Sendable {
    /// File name inside the library's attachments folder.
    public var fileName: String
    public var kind: SheetKind
    /// The name of the file the parent picked (for display).
    public var originalName: String

    public init(fileName: String, kind: SheetKind, originalName: String) {
        self.fileName = fileName
        self.kind = kind
        self.originalName = originalName
    }
}

/// Where a song's notes came from.
public enum NotesOrigin: String, Codable, Sendable {
    /// Transcribed from the sound of the YouTube video.
    case video
    /// Transcribed from an audio file the parent chose.
    case audioFile
    /// Imported from a MIDI or MusicXML file.
    case sheetMusic
}

/// What the app worked out about a song's notes, for the library and the start screen.
public struct SongInfo: Codable, Hashable, Sendable {
    public var origin: NotesOrigin
    /// "G major", when known.
    public var keyName: String?
    /// Quarter-note tempo at 100 % speed, when known.
    public var tempoBPM: Double?
    public var noteCount: Int
    public var date: Date
    /// Seconds into the video where the notes' beat 0 falls (learned songs), so the notes can be shown
    /// and heard in time with the video.
    public var videoTimeOfBeatZero: Double?

    public init(origin: NotesOrigin, keyName: String? = nil, tempoBPM: Double? = nil, noteCount: Int, date: Date = Date(),
                videoTimeOfBeatZero: Double? = nil) {
        self.origin = origin
        self.keyName = keyName
        self.tempoBPM = tempoBPM
        self.noteCount = noteCount
        self.date = date
        self.videoTimeOfBeatZero = videoTimeOfBeatZero
    }
}

/// A song the child practises: a YouTube video, the notes the app learned from it (or imported), and the
/// child's progress. (The video-pacing fields are kept so older libraries still load.)
public struct Piece: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    /// 11-character YouTube video id.
    public var videoID: String
    public var createdAt: Date
    public var lastPracticedAt: Date?

    /// Optional score for display and/or following.
    public var sheet: SheetAttachment?
    /// Optional second attachment used only for display (e.g. a PDF when the notes come from MIDI).
    public var displaySheet: SheetAttachment?

    /// Quarter-note tempo of the video at 1x, if known (typed, tapped or from the score).
    public var videoBPM: Double?
    /// Score <-> video synchronisation (score following needs this).
    public var syncMap: SyncMap?
    /// True when a reference track learned by listening to the video exists on disk.
    public var hasLearnedTrack: Bool

    public var loop: LoopRange?
    public var preferredMode: CoachMode
    /// Where the video was when the child last stopped.
    public var resumeTime: Double
    /// Manual playback-rate preference used when the coach is off (1 = normal).
    public var manualRate: Double
    /// Progress in the falling-notes game (level, bests, history). Nil until the first game.
    public var game: GameProgress?
    /// 1...5 difficulty of the song's notes, once known (for the library and suggestions).
    public var difficulty: Int?
    /// Key, tempo and origin of the notes in `sheet`, when the app learned or imported them.
    public var songInfo: SongInfo?

    public init(id: UUID = UUID(), title: String, videoID: String, createdAt: Date = Date(),
                lastPracticedAt: Date? = nil, sheet: SheetAttachment? = nil, displaySheet: SheetAttachment? = nil,
                videoBPM: Double? = nil, syncMap: SyncMap? = nil, hasLearnedTrack: Bool = false,
                loop: LoopRange? = nil, preferredMode: CoachMode = .waitForMe, resumeTime: Double = 0,
                manualRate: Double = 1, game: GameProgress? = nil, difficulty: Int? = nil, songInfo: SongInfo? = nil) {
        self.id = id
        self.title = title
        self.videoID = videoID
        self.createdAt = createdAt
        self.lastPracticedAt = lastPracticedAt
        self.sheet = sheet
        self.displaySheet = displaySheet
        self.videoBPM = videoBPM
        self.syncMap = syncMap
        self.hasLearnedTrack = hasLearnedTrack
        self.loop = loop
        self.preferredMode = preferredMode
        self.resumeTime = resumeTime
        self.manualRate = manualRate
        self.game = game
        self.difficulty = difficulty
        self.songInfo = songInfo
    }

    /// The attachment to display as sheet music, if any.
    public var sheetForDisplay: SheetAttachment? {
        if let s = sheet, s.kind.isDisplayable { return s }
        return displaySheet
    }
}
