import Foundation
import PianoCoachCore

/// Plays notes with the built-in piano, through the app's shared audio engine (`AudioHub`).
final class GameSoundPlayer: @unchecked Sendable {
    private let hub: AudioHub

    init(hub: AudioHub) {
        self.hub = hub
    }

    var isRunning: Bool { hub.isPlaying }

    /// Silences the piano without stopping anything ("sound off").
    var isMuted: Bool {
        get { hub.synth.volume == 0 }
        set { hub.synth.volume = newValue ? 0 : Self.volume }
    }

    private static let volume: Float = 0.6

    /// Makes the piano audible (idempotent).
    func start() throws {
        try hub.startOutput()
    }

    func stop() {
        hub.stopOutput()
    }

    func noteOn(_ midi: Int, velocity: Float = 0.7) {
        hub.synth.noteOn(midi, velocity: velocity)
    }

    func noteOff(_ midi: Int) {
        hub.synth.noteOff(midi)
    }

    func allNotesOff() {
        hub.synth.allNotesOff()
    }
}
