import Foundation
import Observation
import PianoCoachCore

/// Where the sheet music appears relative to the video.
enum SheetLayout: String, CaseIterable, Identifiable, Codable {
    /// Beside the video when there is room (iPad landscape, Mac), otherwise below.
    case automatic
    /// Always below the video.
    case below
    /// Always beside the video.
    case beside

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .below: return "Below the video"
        case .beside: return "Beside the video"
        }
    }
}

/// The parent's preferences, persisted in UserDefaults.
///
/// Each setting is a computed property over ignored storage, calling the `access`/`withMutation`
/// hooks that `@Observable` generates, so SwiftUI still observes it and every change is saved.
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    @ObservationIgnored private var _noteSource: NoteSource
    /// Microphone or MIDI keyboard.
    var noteSource: NoteSource {
        get {
            access(keyPath: \.noteSource)
            return _noteSource
        }
        set {
            withMutation(keyPath: \.noteSource) { _noteSource = newValue }
            defaults.set(newValue.rawValue, forKey: "noteSource")
        }
    }

    @ObservationIgnored private var _sensitivity: Double
    /// How easily a sound counts as a note (0 = only clear notes, 1 = very sensitive).
    var sensitivity: Double {
        get {
            access(keyPath: \.sensitivity)
            return _sensitivity
        }
        set {
            withMutation(keyPath: \.sensitivity) { _sensitivity = newValue }
            defaults.set(newValue, forKey: "sensitivity")
        }
    }

    @ObservationIgnored private var _silenceTimeout: Double
    /// Seconds of silence before the coach pauses the video.
    var silenceTimeout: Double {
        get {
            access(keyPath: \.silenceTimeout)
            return _silenceTimeout
        }
        set {
            withMutation(keyPath: \.silenceTimeout) { _silenceTimeout = newValue }
            defaults.set(newValue, forKey: "silenceTimeout")
        }
    }

    @ObservationIgnored private var _maxLead: Double
    /// How far (seconds) the video may get ahead of the child before it waits.
    var maxLead: Double {
        get {
            access(keyPath: \.maxLead)
            return _maxLead
        }
        set {
            withMutation(keyPath: \.maxLead) { _maxLead = newValue }
            defaults.set(newValue, forKey: "maxLead")
        }
    }

    @ObservationIgnored private var _allowFasterThanNormal: Bool
    /// Allow the coach to play the video faster than normal speed when the child is fast.
    var allowFasterThanNormal: Bool {
        get {
            access(keyPath: \.allowFasterThanNormal)
            return _allowFasterThanNormal
        }
        set {
            withMutation(keyPath: \.allowFasterThanNormal) { _allowFasterThanNormal = newValue }
            defaults.set(newValue, forKey: "allowFasterThanNormal")
        }
    }

    @ObservationIgnored private var _muteVideoWhileListening: Bool
    /// Mute the video while the coach listens with the microphone.
    var muteVideoWhileListening: Bool {
        get {
            access(keyPath: \.muteVideoWhileListening)
            return _muteVideoWhileListening
        }
        set {
            withMutation(keyPath: \.muteVideoWhileListening) { _muteVideoWhileListening = newValue }
            defaults.set(newValue, forKey: "muteVideoWhileListening")
        }
    }

    @ObservationIgnored private var _echoCancellation: Bool
    /// Apple's echo cancellation on the microphone (experimental).
    var echoCancellation: Bool {
        get {
            access(keyPath: \.echoCancellation)
            return _echoCancellation
        }
        set {
            withMutation(keyPath: \.echoCancellation) { _echoCancellation = newValue }
            defaults.set(newValue, forKey: "echoCancellation")
        }
    }

    @ObservationIgnored private var _voiceCommandsEnabled: Bool
    /// Listen for spoken commands.
    var voiceCommandsEnabled: Bool {
        get {
            access(keyPath: \.voiceCommandsEnabled)
            return _voiceCommandsEnabled
        }
        set {
            withMutation(keyPath: \.voiceCommandsEnabled) { _voiceCommandsEnabled = newValue }
            defaults.set(newValue, forKey: "voiceCommandsEnabled")
        }
    }

    @ObservationIgnored private var _requireWakeWord: Bool
    /// Only react to commands that start with "Coach" / "Hey coach".
    var requireWakeWord: Bool {
        get {
            access(keyPath: \.requireWakeWord)
            return _requireWakeWord
        }
        set {
            withMutation(keyPath: \.requireWakeWord) { _requireWakeWord = newValue }
            defaults.set(newValue, forKey: "requireWakeWord")
        }
    }

    @ObservationIgnored private var _sheetLayout: SheetLayout
    /// Where the sheet music appears relative to the video.
    var sheetLayout: SheetLayout {
        get {
            access(keyPath: \.sheetLayout)
            return _sheetLayout
        }
        set {
            withMutation(keyPath: \.sheetLayout) { _sheetLayout = newValue }
            defaults.set(newValue.rawValue, forKey: "sheetLayout")
        }
    }

    @ObservationIgnored private var _sheetZoom: Double
    /// Sheet-music zoom (1 = 100 %).
    var sheetZoom: Double {
        get {
            access(keyPath: \.sheetZoom)
            return _sheetZoom
        }
        set {
            withMutation(keyPath: \.sheetZoom) { _sheetZoom = newValue }
            defaults.set(newValue, forKey: "sheetZoom")
        }
    }

    @ObservationIgnored private var _learnLatency: Double
    /// Speaker-to-microphone delay used when learning a song (seconds).
    var learnLatency: Double {
        get {
            access(keyPath: \.learnLatency)
            return _learnLatency
        }
        set {
            withMutation(keyPath: \.learnLatency) { _learnLatency = newValue }
            defaults.set(newValue, forKey: "learnLatency")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _noteSource = NoteSource(rawValue: defaults.string(forKey: "noteSource") ?? "") ?? .microphone
        _sensitivity = defaults.object(forKey: "sensitivity") as? Double ?? 0.5
        _silenceTimeout = defaults.object(forKey: "silenceTimeout") as? Double ?? 2.5
        _maxLead = defaults.object(forKey: "maxLead") as? Double ?? 0.8
        _allowFasterThanNormal = defaults.object(forKey: "allowFasterThanNormal") as? Bool ?? false
        _muteVideoWhileListening = defaults.object(forKey: "muteVideoWhileListening") as? Bool ?? true
        _echoCancellation = defaults.object(forKey: "echoCancellation") as? Bool ?? false
        _voiceCommandsEnabled = defaults.object(forKey: "voiceCommandsEnabled") as? Bool ?? true
        _requireWakeWord = defaults.object(forKey: "requireWakeWord") as? Bool ?? false
        _sheetLayout = SheetLayout(rawValue: defaults.string(forKey: "sheetLayout") ?? "") ?? .automatic
        _sheetZoom = defaults.object(forKey: "sheetZoom") as? Double ?? 1.0
        _learnLatency = defaults.object(forKey: "learnLatency") as? Double ?? 0.08
    }

    func resetCoachDefaults() {
        sensitivity = 0.5
        silenceTimeout = 2.5
        maxLead = 0.8
        allowFasterThanNormal = false
        muteVideoWhileListening = true
        echoCancellation = false
        learnLatency = 0.08
    }
}
