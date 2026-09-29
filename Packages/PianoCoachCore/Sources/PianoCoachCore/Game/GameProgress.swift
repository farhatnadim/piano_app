import Foundation

/// How a game changed the player's level on a song.
public enum LevelChange: Equatable, Sendable {
    case up(to: Double)
    case down(to: Double)
    case same
}

/// One finished game, kept in a song's history.
public struct GameRecord: Codable, Hashable, Sendable {
    public var date: Date
    public var mode: GameMode
    public var hands: HandSelection
    public var speed: Double
    public var accuracy: Double
    public var stars: Int
    public var score: Int
    public var completed: Bool

    public init(date: Date, mode: GameMode, hands: HandSelection, speed: Double, accuracy: Double,
                stars: Int, score: Int, completed: Bool) {
        self.date = date
        self.mode = mode
        self.hands = hands
        self.speed = speed
        self.accuracy = accuracy
        self.stars = stars
        self.score = score
        self.completed = completed
    }
}

/// A player's progress on one song: the speed the next game starts at (their "level") and bests.
public struct GameProgress: Codable, Hashable, Sendable {
    /// Speed (fraction of the song's tempo) the next game starts at.
    public var speed: Double
    public var bestStars: Int
    public var bestScore: Int
    public var bestAccuracy: Double
    public var gamesPlayed: Int
    /// Most recent last; at most `historyLimit` entries.
    public var history: [GameRecord]

    public static let historyLimit = 30
    public static let minSpeed = 0.3
    public static let maxSpeed = 1.2

    public init(speed: Double = 0.6) {
        self.speed = speed
        bestStars = 0
        bestScore = 0
        bestAccuracy = 0
        gamesPlayed = 0
        history = []
    }

    /// The level shown to the child: speed in tens of percent (60 % = level 6).
    public var level: Int { Int((speed * 10).rounded()) }

    /// Records a finished game and moves the starting speed: up after a great game at (or above) the
    /// current level, down after a hard one, otherwise to where adaptive speed ended.
    @discardableResult
    public mutating func record(_ result: GameResult, date: Date = Date()) -> LevelChange {
        gamesPlayed += 1
        bestScore = max(bestScore, result.score)
        bestStars = max(bestStars, result.stars)
        bestAccuracy = max(bestAccuracy, result.accuracy)
        history.append(GameRecord(date: date, mode: result.mode, hands: result.hands, speed: result.endSpeed,
                                  accuracy: result.accuracy, stars: result.stars, score: result.score,
                                  completed: result.completed))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }

        let old = speed
        var next: Double
        if result.completed && result.accuracy >= 0.9 && result.endSpeed >= speed - 0.051 {
            next = max(speed, result.endSpeed) + 0.1
        } else if result.accuracy < 0.5 {
            next = min(speed, result.endSpeed) - 0.1
        } else {
            next = result.endSpeed
        }
        next = (max(Self.minSpeed, min(Self.maxSpeed, next)) * 20).rounded() / 20   // steps of 5 %
        speed = next
        if next > old + 0.001 { return .up(to: next) }
        if next < old - 0.001 { return .down(to: next) }
        return .same
    }
}

/// A rough 1...5 difficulty for a song, to show in the library and suggest what to play next.
public struct ChartDifficulty: Equatable, Sendable {
    public var level: Int
    /// Required notes per second at the song's tempo.
    public var notesPerSecond: Double
    public var largestChord: Int
    public var usesBothHands: Bool
    /// Semitones between the lowest and highest note.
    public var range: Int

    public static func estimate(_ chart: NoteChart) -> ChartDifficulty {
        let notes = chart.notes
        guard let first = notes.first else {
            return ChartDifficulty(level: 1, notesPerSecond: 0, largestChord: 0, usesBothHands: false, range: 0)
        }
        let seconds = max(1, (chart.endBeat - first.time) * chart.secondsPerBeat(atSpeed: 1))
        let nps = Double(notes.count) / seconds
        let largestChord = chart.chords.map(\.count).max() ?? 1
        let bothHands = Set(notes.map(\.hand)).count > 1
        let range = chart.highestMIDI - chart.lowestMIDI
        var points = nps / 1.2                                   // ~1.2 notes/s is gentle
        points += Double(max(0, largestChord - 1)) * 0.5
        points += bothHands ? 0.8 : 0
        points += Double(max(0, range - 12)) / 12 * 0.5
        let level = max(1, min(5, Int(points.rounded(.up))))
        return ChartDifficulty(level: level, notesPerSecond: nps, largestChord: largestChord,
                               usesBothHands: bothHands, range: range)
    }
}
