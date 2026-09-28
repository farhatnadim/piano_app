import Foundation

/// Things the child (or parent) can say to the app.
public enum VoiceCommand: Equatable, Hashable, Sendable {
    case play
    case pause
    case slower
    case faster
    case normalSpeed
    /// "half speed", "speed 75" -> 0.5 / 0.75.
    case setSpeed(Double)
    case showMusic
    case hideMusic
    case followMe
    case waitForMe
    case coachOff
    /// "go back", "back a bit", "rewind" — jump back a few seconds (or one measure with a score).
    case goBack
    /// "go forward", "skip ahead".
    case goForward
    /// "again", "repeat", "one more time" — replay the current loop or the last few seconds.
    case again
    /// "from the top", "start over", "from the beginning".
    case restart
    /// "measure twelve", "bar 12", "go to measure 12".
    case goToMeasure(Int)
    /// "loop this", "practice this part".
    case loopThis
    /// "stop looping", "no loop".
    case stopLoop
    /// "sound on", "unmute".
    case soundOn
    /// "sound off", "mute", "quiet".
    case soundOff
    /// "what can I say", "help".
    case help

    /// Short confirmation shown on screen after the command is recognised.
    public var confirmation: String {
        switch self {
        case .play: return "Play"
        case .pause: return "Pause"
        case .slower: return "Slower"
        case .faster: return "Faster"
        case .normalSpeed: return "Normal speed"
        case .setSpeed(let r): return "Speed \(Int((r * 100).rounded()))%"
        case .showMusic: return "Showing the music"
        case .hideMusic: return "Hiding the music"
        case .followMe: return "Follow me: on"
        case .waitForMe: return "Wait for me: on"
        case .coachOff: return "Coach off"
        case .goBack: return "Going back"
        case .goForward: return "Skipping ahead"
        case .again: return "Again!"
        case .restart: return "From the top"
        case .goToMeasure(let n): return "Measure \(n)"
        case .loopThis: return "Looping this part"
        case .stopLoop: return "Loop off"
        case .soundOn: return "Sound on"
        case .soundOff: return "Sound off"
        case .help: return "Here's what you can say"
        }
    }
}
