import Foundation

/// How the coach drives the video.
public enum CoachMode: String, Codable, CaseIterable, Sendable {
    /// The video behaves like a normal player.
    case off
    /// Pause when the child stops playing, resume when they start again. No setup needed.
    case waitForMe
    /// Follow the child's position and speed through a reference track (learned or from a score).
    case followMe

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .waitForMe: return "Wait for me"
        case .followMe: return "Follow me"
        }
    }
}

/// A command the coach sends to the video player.
public enum PlayerCommand: Equatable, Sendable {
    case play
    case pause
    case setRate(Double)
    case seek(to: Double)
}

/// Snapshot of the score follower's belief about where the child is.
public struct FollowerState: Equatable, Sendable {
    /// Index of the last track event the child played, or -1 before they start.
    public var eventIndex: Int
    /// The child's position expressed in video seconds (the matched event's `videoTime`).
    public var videoTime: Double
    /// Confidence 0...1 in `eventIndex`.
    public var confidence: Double
    /// Clock time (caller's clock) of the last onset matched to the track, if any.
    public var lastMatchClockTime: Double?
    /// Child's speed relative to the video at 1x (0.5 = half speed), from recent matched notes. Nil until known.
    public var tempoRatio: Double?
    /// True when the last update moved the position non-sequentially (a skip or restart).
    public var jumped: Bool

    public init(eventIndex: Int = -1, videoTime: Double = 0, confidence: Double = 0,
                lastMatchClockTime: Double? = nil, tempoRatio: Double? = nil, jumped: Bool = false) {
        self.eventIndex = eventIndex
        self.videoTime = videoTime
        self.confidence = confidence
        self.lastMatchClockTime = lastMatchClockTime
        self.tempoRatio = tempoRatio
        self.jumped = jumped
    }

    public var hasStarted: Bool { eventIndex >= 0 }
}

/// Everything the pacing controller looks at on each tick.
public struct PacingInput: Equatable, Sendable {
    /// Monotonic clock in seconds (same clock as onset/follower times).
    public var now: Double
    /// Current video position in seconds.
    public var videoTime: Double
    /// Whether the video is currently playing.
    public var videoIsPlaying: Bool
    /// Playback rate currently applied to the video.
    public var currentRate: Double
    /// Clock time of the most recent onset of any kind (the child is "active"), if any.
    public var lastOnsetClockTime: Double?
    /// Follower state (only in `.followMe`).
    public var follower: FollowerState?
    /// Where the child is expected to be *now* in video seconds, extrapolated between notes (only in `.followMe`).
    public var childVideoTime: Double?
    /// Expected seconds (at the child's pace) until the next note is due; lets the silence timeout
    /// stretch across long held notes. Nil when unknown.
    public var expectedGapSeconds: Double?

    public init(now: Double, videoTime: Double, videoIsPlaying: Bool, currentRate: Double,
                lastOnsetClockTime: Double?, follower: FollowerState? = nil, childVideoTime: Double? = nil,
                expectedGapSeconds: Double? = nil) {
        self.now = now
        self.videoTime = videoTime
        self.videoIsPlaying = videoIsPlaying
        self.currentRate = currentRate
        self.lastOnsetClockTime = lastOnsetClockTime
        self.follower = follower
        self.childVideoTime = childVideoTime
        self.expectedGapSeconds = expectedGapSeconds
    }
}

/// What the coach is doing, for display.
public enum PacingStatus: Equatable, Sendable {
    case idle
    /// Waiting for the child's first note before starting the video.
    case waitingToStart
    /// Video playing along with the child.
    case playingAlong(rate: Double)
    /// Paused because the child stopped playing.
    case pausedForSilence
    /// Paused because the video got ahead of the child.
    case pausedAhead
    /// Paused by a person (tap or voice); the coach will not resume on its own.
    case pausedByUser
    /// The video was moved to where the child is.
    case jumpedToChild

    public var message: String {
        switch self {
        case .idle: return "Coach is off"
        case .waitingToStart: return "Start playing when you're ready"
        case .playingAlong(let rate):
            return rate < 0.999 || rate > 1.001 ? "Playing along at \(Int((rate * 100).rounded()))%" : "Playing along"
        case .pausedForSilence: return "Waiting for you…"
        case .pausedAhead: return "Waiting for you to catch up…"
        case .pausedByUser: return "Paused"
        case .jumpedToChild: return "Following you"
        }
    }
}

/// A loop region in video seconds.
public struct LoopRange: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public var duration: Double { end - start }
}
