import Foundation

/// Things the child (or parent) can say to the app while a song is open.
public enum VoiceCommand: Equatable, Hashable, Sendable {
    /// "play", "start", "go" — start the game, or carry on where it stopped.
    case play
    /// "stop", "pause", "wait" — stop where we are.
    case pause
    /// "slower", "reduce speed".
    case slower
    /// "faster", "increase speed".
    case faster
    case normalSpeed
    /// "half speed", "speed 75" -> 0.5 / 0.75.
    case setSpeed(Double)
    /// "listen", "play the song", "show me" — the app plays the song while the notes fall.
    case listen
    /// "show the notes" — the scrolling staff.
    case showNotes
    /// "show the keys" — falling notes over the keyboard.
    case showKeys
    /// "right hand", "left hand", "both hands".
    case hands(HandSelection)
    /// "again", "one more time", "from the top" — start the song over.
    case again
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
        case .pause: return "Stop"
        case .slower: return "Slower"
        case .faster: return "Faster"
        case .normalSpeed: return "Normal speed"
        case .setSpeed(let r): return "Speed \(Int((r * 100).rounded()))%"
        case .listen: return "Listen"
        case .showNotes: return "Showing the notes"
        case .showKeys: return "Showing the keys"
        case .hands(let hands): return hands.displayName
        case .again: return "Again!"
        case .soundOn: return "Sound on"
        case .soundOff: return "Sound off"
        case .help: return "Here's what you can say"
        }
    }
}
