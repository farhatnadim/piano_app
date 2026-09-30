import Foundation

/// Checks the transcription model's notes against the recording's spectrum, and drops the ones the sound
/// doesn't back up.
///
/// The model is good at hearing *that* a note started, but a piano's overtones fool it into a few extra notes
/// an octave (or an octave and a fifth) above a real one, and a noisy recording gives it faint notes that
/// aren't there at all. So for each note a Fourier transform is taken just after its onset, and the note is
/// kept only when:
///
/// 1. there is a clear peak at the note's own frequency (or, for the lowest keys, whose fundamental a piano
///    barely produces, its second harmonic) — clearly above the surrounding spectrum; and
/// 2. it isn't an *overtone ghost*: a much fainter note starting together with a stronger note an octave,
///    a twelfth or two octaves below it, whose own frequency is no louder than the neighbouring overtones of
///    that lower note would make it.
public enum SpectralNoteFilter {
    public struct Settings: Hashable, Sendable {
        /// Seconds after the onset at which the analysis window starts (skips the hammer's noise).
        public var onsetSkip = 0.02
        /// A note's peak must be this many times the median of the surrounding spectrum (about +10 dB).
        public var peakProminence: Float = 3
        /// ...and this fraction of the loudest bin in the window (about -46 dB).
        public var peakFloor: Float = 0.005
        /// Ghost candidates: notes this much fainter (activation) than a lower note starting with them.
        public var ghostActivationRatio = 0.6
        /// Notes this much fainter than a note an octave above that sounds throughout them are phantoms.
        public var subOctaveActivationRatio = 0.5
        /// Notes starting within this many seconds of each other count as starting together.
        public var onsetTolerance = 0.05
        /// A candidate ghost survives when its frequency is at least this many times louder than the next
        /// overtone up of the lower note (a real note adds its own energy there; a piano's overtones
        /// otherwise fall off gently).
        public var ghostHarmonicRatio: Float = 2.5

        public init() {}
    }

    /// The notes of `notes` that `samples` (mono, the audio the notes' times refer to) support.
    public static func supportedNotes(_ notes: [TranscribedNote], samples: [Float], sampleRate: Double,
                                      settings: Settings = .init()) -> [TranscribedNote] {
        guard sampleRate > 0, !samples.isEmpty, !notes.isEmpty else { return notes }
        let analyzer = Analyzer(samples: samples, sampleRate: sampleRate, settings: settings)
        let sorted = notes.sorted { ($0.start, $0.midi) < ($1.start, $1.midi) }
        return sorted.filter { note in
            guard analyzer.hasPeak(for: note) else { return false }
            guard !isSubOctaveGhost(note, in: sorted, settings: settings) else { return false }
            guard let parent = ghostParent(of: note, in: sorted, settings: settings) else { return true }
            return analyzer.standsOut(note, aboveOvertonesOf: parent)
        }
    }

    /// A stronger note an octave, a twelfth or two octaves below `note` that is sounding when it starts
    /// (started with it or earlier and still going), if any.
    static func ghostParent(of note: TranscribedNote, in notes: [TranscribedNote], settings: Settings)
        -> TranscribedNote? {
        var best: TranscribedNote?
        for other in notes {
            if other.start > note.start + settings.onsetTolerance { break }
            let interval = note.midi - other.midi
            guard interval == 12 || interval == 19 || interval == 24,
                  other.end >= note.start + settings.onsetTolerance,
                  note.amplitude < other.amplitude * settings.ghostActivationRatio else { continue }
            if best == nil || other.amplitude > best!.amplitude { best = other }
        }
        return best
    }

    /// Whether a much stronger note an octave *above* `note` sounds for the whole of it: the model
    /// sometimes hears a faint phantom an octave below a ringing note. A piano's lowest partial is too
    /// weak for the spectrum to settle this, so the activations decide.
    static func isSubOctaveGhost(_ note: TranscribedNote, in notes: [TranscribedNote], settings: Settings) -> Bool {
        for other in notes {
            if other.start > note.start + settings.onsetTolerance { break }
            guard other.midi == note.midi + 12,
                  other.end >= note.end - settings.onsetTolerance,
                  note.amplitude < other.amplitude * settings.subOctaveActivationRatio else { continue }
            return true
        }
        return false
    }

    public static func frequency(ofMIDI midi: Int) -> Double {
        440 * pow(2, Double(midi - 69) / 12)
    }

    /// Spectra at note onsets, computed once per distinct window.
    private final class Analyzer {
        private let samples: [Float]
        private let sampleRate: Double
        private let settings: Settings
        private let fft: RealFFT
        private var cache: [Int: [Float]] = [:]

        init(samples: [Float], sampleRate: Double, settings: Settings) {
            self.samples = samples
            self.sampleRate = sampleRate
            self.settings = settings
            // About 370 ms at 22.05 kHz: 2.7 Hz bins, enough to tell semitones apart from about C2 up.
            var size = 16
            while Double(size) < sampleRate * 0.35 { size *= 2 }
            fft = RealFFT(size: min(size, 1 << 16))
        }

        /// Magnitudes of the window starting `onsetSkip` after `note`'s start (zero-padded past the end).
        private func spectrum(at start: Double) -> [Float] {
            let from = max(0, Int((start + settings.onsetSkip) * sampleRate))
            if let cached = cache[from] { return cached }
            var window = [Float](repeating: 0, count: fft.size)
            let available = max(0, min(fft.size, samples.count - from))
            if available > 0 {
                window.replaceSubrange(0..<available, with: samples[from..<(from + available)])
            }
            let magnitudes = fft.magnitudes(window)
            cache[from] = magnitudes
            return magnitudes
        }

        private func bin(_ hz: Double) -> Int {
            Int((hz * Double(fft.size) / sampleRate).rounded())
        }

        /// Loudest bin within a quarter tone of `hz`.
        private func peak(_ m: [Float], near hz: Double) -> Float {
            let lower = max(0, bin(hz / pow(2, 1.0 / 24)))
            let upper = min(m.count - 1, max(lower, bin(hz * pow(2, 1.0 / 24))))
            guard lower < m.count else { return 0 }
            return m[lower...upper].max() ?? 0
        }

        /// Median magnitude between `hz / 1.5` and `hz * 1.5`, leaving out the quarter tone around `hz`.
        private func background(_ m: [Float], around hz: Double) -> Float {
            let lower = max(1, bin(hz / 1.5))
            let upper = min(m.count - 1, bin(hz * 1.5))
            let skipLower = bin(hz / pow(2, 1.0 / 24)), skipUpper = bin(hz * pow(2, 1.0 / 24))
            guard lower < upper else { return 0 }
            var values = (lower...upper).filter { $0 < skipLower || $0 > skipUpper }.map { m[$0] }
            guard !values.isEmpty else { return 0 }
            values.sort()
            return values[values.count / 2]
        }

        func hasPeak(for note: TranscribedNote) -> Bool {
            let m = spectrum(at: note.start)
            let loudest = m.max() ?? 0
            guard loudest > 0 else { return false }
            // Below about C2 the piano's fundamental is faint and the bins too coarse: use the octave above.
            let hz = frequency(ofMIDI: note.midi) * (note.midi < 36 ? 2 : 1)
            let peak = peak(m, near: hz)
            let floor = max(background(m, around: hz) * settings.peakProminence, loudest * settings.peakFloor)
            return peak >= floor
        }

        /// Whether `note`'s frequency is much louder than the next overtone up of `parent`.
        func standsOut(_ note: TranscribedNote, aboveOvertonesOf parent: TranscribedNote) -> Bool {
            let m = spectrum(at: note.start)
            let base = frequency(ofMIDI: parent.midi)
            let harmonic = Double(note.midi - parent.midi == 12 ? 2 : note.midi - parent.midi == 19 ? 3 : 4)
            let own = peak(m, near: base * harmonic)
            let next = peak(m, near: base * (harmonic + 1))
            return own >= next * settings.ghostHarmonicRatio
        }
    }
}
