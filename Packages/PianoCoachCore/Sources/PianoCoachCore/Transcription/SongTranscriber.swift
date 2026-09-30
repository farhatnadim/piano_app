import Foundation

/// The whole path from a recording to notes: resampled to the model's rate, guarded against digital
/// silence (`RecordingCleanup`), transcribed with a Basic Pitch model supplied by the caller
/// (`BasicPitch.transcribe`), cleaned of notes found where there was no sound, and checked against the
/// recording's spectrum (`SpectralNoteFilter`) to drop overtone ghosts and notes the sound doesn't back up.
public enum SongTranscriber {
    /// Notes in `samples` (mono, any sample rate). Times are seconds from the first sound in the
    /// recording (less a short margin): silence at the start is trimmed.
    public static func notes(inRecording samples: [Float], sampleRate: Double, progress: ((Double) -> Void)? = nil,
                             runModel: ([Float]) throws -> (note: [Float], onset: [Float])) rethrows -> [TranscribedNote] {
        try transcribe(recording: samples, sampleRate: sampleRate, progress: progress, runModel: runModel).notes
    }

    /// Like `notes(inRecording:...)`, also saying how many seconds of silence were cut from the start of
    /// the recording (so note times + `trimmedSeconds` = recording time).
    public static func transcribe(recording samples: [Float], sampleRate: Double, progress: ((Double) -> Void)? = nil,
                                  runModel: ([Float]) throws -> (note: [Float], onset: [Float]))
        rethrows -> (notes: [TranscribedNote], trimmedSeconds: Double) {
        guard !samples.isEmpty, sampleRate > 0 else { return ([], 0) }
        let audio = sampleRate == BasicPitch.sampleRate ? samples : BasicPitch.resample(samples, from: sampleRate)
        let (prepared, trimmed) = RecordingCleanup.prepare(audio, sampleRate: BasicPitch.sampleRate)
        let notes = try BasicPitch.transcribe(samples: prepared, progress: progress, runModel: runModel)
        let sounding = RecordingCleanup.droppingNotesInSilence(notes, samples: prepared, sampleRate: BasicPitch.sampleRate)
        return (SpectralNoteFilter.supportedNotes(sounding, samples: prepared, sampleRate: BasicPitch.sampleRate), trimmed)
    }
}
