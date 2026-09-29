import Foundation

/// The whole path from a recording to notes: resampled to the model's rate, guarded against digital
/// silence (`RecordingCleanup`), transcribed with a Basic Pitch model supplied by the caller
/// (`BasicPitch.transcribe`), and cleaned of notes found where there was no sound.
public enum SongTranscriber {
    /// Notes in `samples` (mono, any sample rate). Times are seconds from the first sound in the
    /// recording (less a short margin): silence at the start is trimmed.
    public static func notes(inRecording samples: [Float], sampleRate: Double, progress: ((Double) -> Void)? = nil,
                             runModel: ([Float]) throws -> (note: [Float], onset: [Float])) rethrows -> [TranscribedNote] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        let audio = sampleRate == BasicPitch.sampleRate ? samples : BasicPitch.resample(samples, from: sampleRate)
        let prepared = RecordingCleanup.prepare(audio, sampleRate: BasicPitch.sampleRate).samples
        let notes = try BasicPitch.transcribe(samples: prepared, progress: progress, runModel: runModel)
        return RecordingCleanup.droppingNotesInSilence(notes, samples: prepared, sampleRate: BasicPitch.sampleRate)
    }
}
