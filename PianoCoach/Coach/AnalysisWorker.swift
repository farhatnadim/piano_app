import Foundation
import PianoCoachCore

/// An onset stamped with `MonotonicClock` time.
struct TimedOnset: Sendable {
    var onset: NoteOnset
    var clockTime: Double
}

/// Runs `OnsetAnalyzer` on its own serial queue so the audio thread and the main thread never wait
/// for the FFTs. Results are delivered on the main actor.
final class AnalysisWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PianoCoach.AnalysisWorker", qos: .userInteractive)
    // Accessed only on `queue`.
    private var analyzer: OnsetAnalyzer?
    private var sensitivity: Float = 0.5
    private var lastLevelReport: Double = 0

    /// Receives onsets (possibly empty) and the current input level in dBFS, on the main actor.
    /// Called for every chunk that produced onsets, and at most ~15 times per second otherwise.
    var onResult: (@MainActor @Sendable ([TimedOnset], Float) -> Void)?

    /// Called on the audio thread; copies nothing further and returns immediately.
    func process(_ chunk: AudioChunk) {
        queue.async { [weak self] in
            self?.analyze(chunk)
        }
    }

    /// Changes onset sensitivity (0...1) and restarts analysis.
    func setSensitivity(_ value: Float) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sensitivity = value
            self.analyzer = nil
        }
    }

    /// Drops analysis state (e.g. after the microphone restarts).
    func reset() {
        queue.async { [weak self] in
            self?.analyzer = nil
        }
    }

    private func analyze(_ chunk: AudioChunk) {
        if analyzer == nil || analyzer?.configuration.sampleRate != chunk.sampleRate {
            analyzer = OnsetAnalyzer(sampleRate: chunk.sampleRate, sensitivity: sensitivity)
        }
        guard let analyzer else { return }
        // The analyser's clock at the first sample of this chunk corresponds to chunk.startTime.
        let clockAtChunkStart = analyzer.clock
        let onsets = analyzer.process(chunk.samples)
        let timed = onsets.map { TimedOnset(onset: $0, clockTime: chunk.startTime + ($0.time - clockAtChunkStart)) }
        let level = analyzer.levelDB
        let now = chunk.startTime
        guard !timed.isEmpty || now - lastLevelReport >= 1.0 / 15 else { return }
        lastLevelReport = now
        guard let handler = onResult else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler(timed, level) }
        }
    }
}
