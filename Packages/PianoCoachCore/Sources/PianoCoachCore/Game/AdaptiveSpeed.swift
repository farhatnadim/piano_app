import Foundation

/// Decides when a game should slow down or speed up, from how each chord went.
///
/// Each chord contributes a "struggle" value (positive = the player had trouble, negative = easy).
/// When the average over the last few chords is clearly high the speed drops; when it is clearly low
/// (and the player keeps hitting the notes) the speed rises a little. After a change the controller
/// waits for a fresh window of chords before changing again.
public struct AdaptiveSpeedController: Sendable {
    public var minSpeed: Double
    public var maxSpeed: Double
    /// Chords considered for each decision.
    public var window: Int
    /// Average struggle at or above which the speed drops.
    public var slowDownAt: Double
    /// Average struggle at or below which the speed rises.
    public var speedUpAt: Double
    public var slowDownFactor: Double
    public var speedUpFactor: Double

    private var recent: [Double] = []
    private var sinceChange = 0

    public init(minSpeed: Double = 0.3, maxSpeed: Double = 1.2, window: Int = 8,
                slowDownAt: Double = 0.45, speedUpAt: Double = -0.2,
                slowDownFactor: Double = 0.85, speedUpFactor: Double = 1.08) {
        self.minSpeed = minSpeed
        self.maxSpeed = maxSpeed
        self.window = window
        self.slowDownAt = slowDownAt
        self.speedUpAt = speedUpAt
        self.slowDownFactor = slowDownFactor
        self.speedUpFactor = speedUpFactor
    }

    /// Records one chord (or a wrong note) and returns a new speed if it should change.
    public mutating func record(struggle: Double, currentSpeed: Double) -> Double? {
        recent.append(struggle)
        if recent.count > window { recent.removeFirst(recent.count - window) }
        sinceChange += 1
        guard recent.count >= window, sinceChange >= window else { return nil }
        let average = recent.reduce(0, +) / Double(recent.count)
        var next = currentSpeed
        if average >= slowDownAt {
            next = currentSpeed * slowDownFactor
        } else if average <= speedUpAt {
            next = currentSpeed * speedUpFactor
        }
        next = (max(minSpeed, min(maxSpeed, next)) * 100).rounded() / 100
        guard abs(next - currentSpeed) >= 0.01 else { return nil }
        sinceChange = 0
        recent.removeAll()
        return next
    }

    /// Struggle for a chord in Play mode, from its timing error (seconds; positive = late) or a miss.
    public static func playStruggle(timingError: Double?, perfectWindow: Double) -> Double {
        guard let e = timingError else { return 1.0 }           // missed
        if abs(e) <= perfectWindow { return -0.4 }
        return e > 0 ? 0.6 : 0.1                                  // late hurts more than early
    }

    /// Struggle for a chord in Learn mode, from how long it waited at the line (seconds; 0 = played on arrival or early).
    public static func learnStruggle(waited: Double) -> Double {
        if waited > 1.0 { return 1.0 }
        if waited > 0.4 { return 0.5 }
        if waited < 0.15 { return -0.5 }
        return 0
    }

    /// Struggle for a wrong note.
    public static let wrongNoteStruggle = 0.4
}
