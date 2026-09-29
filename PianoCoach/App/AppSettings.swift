import Foundation
import Observation
import PianoCoachCore

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

    @ObservationIgnored private var _echoCancellation: Bool
    /// Remove the app's own piano from the microphone signal (Apple's voice processing).
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _noteSource = NoteSource(rawValue: defaults.string(forKey: "noteSource") ?? "") ?? .microphone
        _sensitivity = defaults.object(forKey: "sensitivity") as? Double ?? 0.5
        _echoCancellation = defaults.object(forKey: "echoCancellation") as? Bool ?? false
        _voiceCommandsEnabled = defaults.object(forKey: "voiceCommandsEnabled") as? Bool ?? true
        _requireWakeWord = defaults.object(forKey: "requireWakeWord") as? Bool ?? false
    }

    func resetListeningDefaults() {
        sensitivity = 0.5
        echoCancellation = false
    }
}
