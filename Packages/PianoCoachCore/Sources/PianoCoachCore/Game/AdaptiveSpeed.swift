import Foundation

/// Follows the player's pace ("Follow my speed"): the speed at which they actually play, measured from the
/// time between the chords they play and the time the song gives those chords, as the median of the last
/// few stretches — so one hesitation or one rushed note doesn't swing it.
///
/// Stretches shorter than `minimumSpan` of music are joined to the next one, because two quick notes
/// played a little unevenly say little about the pace. Time the player is excused (reacting to a note that
/// stopped at the line in Learn mode) doesn't count, and a stretch in which they stopped altogether is
/// dropped (`interrupt`). In Play mode, `lateness` also leans the speed a little below or above the pace
/// until a player who has fallen behind (or run ahead) is back with the notes.
public struct PaceFollower: Sendable {
    public var minSpeed: Double
    public var maxSpeed: Double
    /// Stretches the median is taken over.
    public var window = 5
    /// Stretches measured before the speed follows at all.
    public var minimumSamples = 2
    /// Shortest stretch of music measured at once, in seconds at full speed.
    public var minimumSpan = 0.6
    /// How much being behind slows the speed: 0.4 means 10 % slower for every quarter of a second behind.
    public var latenessGain = 0.4
    /// The most the speed leans away from the pace to catch up (0.2 = 20 %).
    public var maximumLean = 0.2

    private var samples: [Double] = []
    private var recentLateness: [Double] = []
    /// The last chord measured from: its beat, when it was played, and time excused since.
    private var reference: (beat: Double, clock: Double, excused: Double)?

    public init(minSpeed: Double = 0.3, maxSpeed: Double = 1.2) {
        self.minSpeed = minSpeed
        self.maxSpeed = maxSpeed
    }

    /// The pace measured so far (median of the recent stretches), once there are enough of them.
    public var pace: Double? {
        samples.count >= minimumSamples ? Self.median(samples) : nil
    }

    /// A chord was played at `clock`: `beat` is its time in the song, `secondsPerBeat` the song's beat at
    /// full speed, and `lateness` (Play mode) how many seconds after its time it was played (negative when
    /// early). Returns the speed to follow, once the pace is known.
    public mutating func played(beat: Double, at clock: Double, secondsPerBeat: Double, lateness: Double? = nil) -> Double? {
        if let lateness {
            recentLateness.append(lateness)
            if recentLateness.count > 3 { recentLateness.removeFirst(recentLateness.count - 3) }
        }
        guard let start = reference else {
            reference = (beat, clock, 0)
            return nil
        }
        let span = (beat - start.beat) * secondsPerBeat
        guard span >= minimumSpan else { return nil }          // keep measuring from the same chord
        reference = (beat, clock, 0)
        let taken = clock - start.clock - start.excused
        guard taken > 0.05 else { return nil }
        samples.append(span / taken)
        if samples.count > window { samples.removeFirst(samples.count - window) }
        guard let pace else { return nil }
        var speed = pace
        if !recentLateness.isEmpty {
            let lean = max(-maximumLean, min(maximumLean, latenessGain * Self.median(recentLateness)))
            speed *= 1 - lean
        }
        return (max(minSpeed, min(maxSpeed, speed)) * 100).rounded() / 100
    }

    /// Time the player may take without it counting as playing slowly.
    public mutating func excuse(_ seconds: Double) {
        reference?.excused += max(0, seconds)
    }

    /// The player stopped (or the song jumped): the stretch in progress is dropped.
    public mutating func interrupt() {
        reference = nil
        recentLateness.removeAll()
    }

    /// Forgets everything measured (the speed was set by hand).
    public mutating func reset() {
        interrupt()
        samples.removeAll()
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
