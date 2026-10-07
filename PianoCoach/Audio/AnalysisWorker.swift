import Foundation
import PianoCoachCore

/// An onset stamped with `MonotonicClock` time.
struct TimedOnset: Sendable {
    var onset: NoteOnset
    var clockTime: Double
}

/// Runs `PianoKeyListener` on its own serial queue so the audio thread and the main thread never wait
/// for the FFTs. Results are delivered on the main actor.
final class AnalysisWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PianoCoach.AnalysisWorker", qos: .userInteractive)
    // Accessed only on `queue`.
    private var listener: PianoKeyListener?
    private var sensitivity: Float = 0.5
    private var expectedKeys: Set<Int> = []
    private var lastLevelReport: Double = 0

    /// Receives the keys heard (possibly none) and the current input level in dBFS, on the main actor.
    /// Called for every chunk in which keys were heard, and at most ~15 times per second otherwise.
    var onResult: (@MainActor @Sendable ([TimedOnset], Float) -> Void)?

    /// Called on the audio thread; copies nothing further and returns immediately.
    func process(_ chunk: AudioChunk) {
        queue.async { [weak self] in
            self?.analyze(chunk)
        }
    }

    /// Changes the sensitivity (0...1) and restarts listening.
    func setSensitivity(_ value: Float) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sensitivity = value
            self.listener = nil
        }
    }

    /// The keys (MIDI numbers) the game is waiting for: heard more readily than the others.
    func setExpectedKeys(_ keys: Set<Int>) {
        queue.async { [weak self] in
            self?.expectedKeys = keys
        }
    }

    /// Drops analysis state (e.g. after the microphone restarts).
    func reset() {
        queue.async { [weak self] in
            self?.listener = nil
        }
    }

    private func analyze(_ chunk: AudioChunk) {
        if listener == nil || listener?.configuration.sampleRate != chunk.sampleRate {
            listener = PianoKeyListener(sampleRate: chunk.sampleRate, sensitivity: sensitivity)
        }
        guard let listener else { return }
        listener.expectedKeys = expectedKeys
        // The listener's clock at the first sample of this chunk corresponds to chunk.startTime.
        let clockAtChunkStart = listener.clock
        let heard = listener.process(chunk.samples)
        let timed = heard.map { h in
            TimedOnset(onset: NoteOnset(time: h.time, strength: 1, levelDB: h.levelDB,
                                        features: .template(forPitches: h.keys), midiPitches: h.keys,
                                        heardAsWrong: h.isWrong),
                       clockTime: chunk.startTime + (h.time - clockAtChunkStart))
        }
        let level = listener.levelDB
        let now = chunk.startTime
        guard !timed.isEmpty || now - lastLevelReport >= 1.0 / 15 else { return }
        lastLevelReport = now
        guard let handler = onResult else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler(timed, level) }
        }
    }
}
