import Foundation

/// How the game treats time.
public enum GameMode: String, Codable, CaseIterable, Sendable {
    /// Notes stop at the line and wait until they are played. Best for learning a new song.
    case learn
    /// Notes keep falling; points for playing them on time.
    case play

    public var displayName: String {
        switch self {
        case .learn: return "Learn"
        case .play: return "Play"
        }
    }
}

/// Which hands the player practises. Notes of the other hand are shown but not required.
public enum HandSelection: String, Codable, CaseIterable, Sendable {
    case both
    case right
    case left

    public var displayName: String {
        switch self {
        case .both: return "Both hands"
        case .right: return "Right hand"
        case .left: return "Left hand"
        }
    }

    public func includes(_ hand: Hand) -> Bool {
        switch self {
        case .both: return true
        case .right: return hand == .right
        case .left: return hand == .left
        }
    }
}

/// How well a note was played.
public enum Judgement: String, Codable, Sendable {
    case perfect
    case good
    case miss
}

/// What happened to a note during a game.
public enum NoteStatus: Equatable, Sendable {
    /// Still to be played.
    case pending
    case hit(Judgement)
    case missed
    /// Belongs to the hand that isn't being practised.
    case notRequired

    public var isDone: Bool {
        switch self {
        case .pending: return false
        default: return true
        }
    }
}

/// Something the UI may want to celebrate or flag.
public enum GameEvent: Equatable, Sendable {
    /// `timingError` is seconds from the note's time: negative when played early, positive when late.
    case hit(noteID: Int, midi: Int, judgement: Judgement, timingError: Double)
    case miss(noteID: Int, midi: Int)
    /// A key that wasn't expected (MIDI), or a sound that matched nothing (microphone; `midi` is the best guess or nil).
    case wrongNote(midi: Int?)
    case speedChanged(from: Double, to: Double)
    case finished
}

/// Tuning for a game.
public struct GameConfiguration: Equatable, Sendable {
    public var mode: GameMode = .learn
    public var hands: HandSelection = .both
    /// Speed to start at, as a fraction of the song's tempo.
    public var startSpeed: Double = 0.6
    /// Follow the player: slow down when they struggle, speed up when they're doing well.
    public var adaptiveSpeed = true
    public var minSpeed: Double = 0.3
    public var maxSpeed: Double = 1.2
    /// Timing error (seconds) that still counts as perfect / good.
    public var perfectWindow: Double = 0.1
    public var goodWindow: Double = 0.25
    /// In Learn mode, how far ahead (beats) a chord may be played before it reaches the line.
    public var earlyWindowBeats: Double = 1.0
    /// Seconds before the first note reaches the line.
    public var leadInSeconds: Double = 3
    /// Microphone: similarity (0...1) between the sound and the expected chord needed to count it as played.
    public var chordSimilarity: Float = 0.5

    public init() {}
}

/// Counts for a game in progress.
public struct GameStats: Equatable, Sendable {
    public var perfect = 0
    public var good = 0
    public var missed = 0
    public var wrongNotes = 0
    public var hits: Int { perfect + good }

    public init() {}
}

/// The outcome of a finished (or stopped) game.
public struct GameResult: Codable, Equatable, Sendable {
    public var score: Int
    public var maxCombo: Int
    public var perfect: Int
    public var good: Int
    public var missed: Int
    public var wrongNotes: Int
    /// 0...1, weighting good notes at 75 % and counting wrong notes against it.
    public var accuracy: Double
    /// 0...3.
    public var stars: Int
    public var startSpeed: Double
    public var endSpeed: Double
    public var mode: GameMode
    public var hands: HandSelection
    /// The song was played to the end.
    public var completed: Bool

    public static func stars(forAccuracy accuracy: Double) -> Int {
        accuracy >= 0.9 ? 3 : accuracy >= 0.75 ? 2 : accuracy >= 0.5 ? 1 : 0
    }
}
