import Foundation

/// Guards the transcription against digital silence.
///
/// A recording often starts or ends with exact zeros (before the video starts, after it ends), and the
/// Basic Pitch model's activations are unreliable there: on a window of pure digital silence it can report
/// a note at high confidence. So silence is trimmed from both ends, a faint noise floor is added so no
/// stretch is exactly zero, and any note found where the recording is essentially silent is dropped.
public enum RecordingCleanup {
    /// Samples ready for the model, and how many seconds were cut from the start.
    ///
    /// - Parameters:
    ///   - silenceThreshold: samples quieter than this (relative to full scale) count as silence at the ends.
    ///   - margin: seconds of silence kept before the first and after the last sound.
    ///   - noiseLevel: peak amplitude of the added noise floor (3e-5 is about -90 dBFS).
    public static func prepare(_ samples: [Float], sampleRate: Double, silenceThreshold: Float = 1e-4,
                               margin: Double = 0.25, noiseLevel: Float = 3e-5) -> (samples: [Float], trimmedSeconds: Double) {
        guard !samples.isEmpty, sampleRate > 0 else { return (samples, 0) }
        var start = 0
        var end = samples.count
        if let first = samples.firstIndex(where: { abs($0) > silenceThreshold }),
           let last = samples.lastIndex(where: { abs($0) > silenceThreshold }) {
            let keep = Int(margin * sampleRate)
            start = max(0, first - keep)
            end = min(samples.count, last + 1 + keep)
        }
        var result = Array(samples[start..<end])
        // A fixed-seed generator, so the same recording always gives the same notes.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in result.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(state >> 40) / Float(1 << 24)          // 0..<1
            result[i] += (unit * 2 - 1) * noiseLevel
        }
        return (result, Double(start) / sampleRate)
    }

    /// Drops notes during which the recording is almost silent: the loudest sample over the note's first
    /// 100 ms is below `relativeThreshold` times the recording's peak (0.003 is about -50 dB), or below
    /// `absoluteThreshold` (about -60 dBFS, for recordings that are silent throughout).
    /// `samples` must be the audio the notes' times refer to.
    public static func droppingNotesInSilence(_ notes: [TranscribedNote], samples: [Float], sampleRate: Double,
                                              relativeThreshold: Float = 0.003,
                                              absoluteThreshold: Float = 0.001) -> [TranscribedNote] {
        guard !samples.isEmpty, sampleRate > 0 else { return notes }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let floor = max(peak * relativeThreshold, absoluteThreshold)
        return notes.filter { note in
            let from = max(0, min(samples.count - 1, Int(note.start * sampleRate)))
            let to = max(from + 1, min(samples.count, Int((note.start + 0.1) * sampleRate)))
            var loudest: Float = 0
            for i in from..<to { loudest = max(loudest, abs(samples[i])) }
            return loudest >= floor
        }
    }
}
