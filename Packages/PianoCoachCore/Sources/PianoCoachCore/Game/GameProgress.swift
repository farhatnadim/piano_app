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
    /// The slowest speed of the game (older records: the speed it ended at).
    public var speed: Double
    public var accuracy: Double
    public var stars: Int
    public var score: Int
    public var completed: Bool
    /// See `GameResult.mastery`; nil for games recorded before it was measured.
    public var mastery: Double?

    public init(date: Date, mode: GameMode, hands: HandSelection, speed: Double, accuracy: Double,
                stars: Int, score: Int, completed: Bool, mastery: Double? = nil) {
        self.mastery = mastery
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

    /// Games in a row at the starting speed whose average mastery decides a speed-up.
    public static let gamesToSpeedUp = 4
    /// Average mastery over those games needed to speed up.
    public static let masteryToSpeedUp = 0.95
    public static let speedUpStep = 0.1

    /// Records a finished game. The speed never changes because of one game: the speed the player chose to
    /// start it at becomes their level, and after `gamesToSpeedUp` games in a row at (or above) that speed
    /// with an average mastery of `masteryToSpeedUp`, the next game starts `speedUpStep` faster.
    @discardableResult
    public mutating func record(_ result: GameResult, date: Date = Date()) -> LevelChange {
        gamesPlayed += 1
        bestScore = max(bestScore, result.score)
        bestStars = max(bestStars, result.stars)
        bestAccuracy = max(bestAccuracy, result.accuracy)
        history.append(GameRecord(date: date, mode: result.mode, hands: result.hands,
                                  speed: min(result.startSpeed, result.lowestSpeed), accuracy: result.accuracy,
                                  stars: result.stars, score: result.score, completed: result.completed,
                                  mastery: result.mastery))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }

        let old = speed
        speed = Self.steps(result.startSpeed)
        if let streak = speedUpStreak(at: speed), streak.games >= Self.gamesToSpeedUp,
           streak.mastery >= Self.masteryToSpeedUp {
            speed = Self.steps(speed + Self.speedUpStep)
        }
        if speed > old + 0.001 { return .up(to: speed) }
        if speed < old - 0.001 { return .down(to: speed) }
        return .same
    }

    /// The latest games in a row played to the end at `speed` or faster (at most `gamesToSpeedUp`), with their
    /// average mastery; nil when the last game doesn't count.
    public func speedUpStreak(at speed: Double) -> (games: Int, mastery: Double)? {
        var masteries: [Double] = []
        for record in history.reversed() {
            guard masteries.count < Self.gamesToSpeedUp, record.completed, let mastery = record.mastery,
                  record.speed >= speed - 0.001 else { break }
            masteries.append(mastery)
        }
        guard !masteries.isEmpty else { return nil }
        return (masteries.count, masteries.reduce(0, +) / Double(masteries.count))
    }

    /// Within the limits, in steps of 5 %.
    private static func steps(_ value: Double) -> Double {
        (max(minSpeed, min(maxSpeed, value)) * 20).rounded() / 20
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
        // Calibrated so an easy one-hand melody is 1, a beginner two-hand piece (Ode to Joy with a
        // simple bass) is 2, and fast, chordal two-hand music reaches 5.
        var points = nps / 2
        points += Double(max(0, largestChord - 1)) * 0.3
        points += bothHands ? 0.4 : 0
        points += Double(max(0, range - 12)) / 12 * 0.25
        let level = max(1, min(5, Int(points.rounded())))
        return ChartDifficulty(level: level, notesPerSecond: nps, largestChord: largestChord,
                               usesBothHands: bothHands, range: range)
    }
}
