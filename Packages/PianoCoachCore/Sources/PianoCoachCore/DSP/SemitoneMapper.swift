import Foundation

/// Converts an FFT magnitude spectrum into 88 per-piano-key energies.
///
/// The mapper picks spectral *peaks* (local maxima), refines each peak's frequency with parabolic
/// interpolation on log magnitudes, and credits the peak to the single nearest key. Compared with
/// summing every bin in a key's band, this keeps a loud note from leaking into its neighbouring
/// semitones (important for adjacent notes such as E then F). Values are square-root compressed,
/// matching the compression assumed by `FeatureVector.template(forPitches:)`.
public struct SemitoneMapper: Sendable {
    public let fftSize: Int
    public let sampleRate: Double
    public let maxFrequency: Double
    /// Peaks weaker than this fraction of the frame's strongest peak are ignored.
    public var relativeFloor: Float = 0.01

    private let minBin: Int
    private let maxBin: Int
    private let binHz: Double

    public init(fftSize: Int, sampleRate: Double, maxFrequency: Double = 5000) {
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.maxFrequency = maxFrequency
        binHz = sampleRate / Double(fftSize)
        minBin = max(2, Int((Pitch.frequency(midi: Pitch.lowestPianoMIDI) * 0.97) / binHz))
        maxBin = min(fftSize / 2 - 2, Int(maxFrequency / binHz))
    }

    /// Returns 88 compressed energies (index 0 = A0) for a magnitude spectrum of `fftSize / 2 + 1` bins.
    public func keyEnergies(magnitudes: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: Pitch.pianoKeyCount)
        guard magnitudes.count > maxBin + 1, minBin < maxBin else { return out }
        magnitudes.withUnsafeBufferPointer { mag in
            var strongest: Float = 0
            for k in minBin...maxBin { strongest = max(strongest, mag[k]) }
            guard strongest > 1e-7 else { return }
            let floor = strongest * relativeFloor
            for k in minBin...maxBin {
                let m = mag[k]
                guard m > floor, m > mag[k - 1], m >= mag[k + 1] else { continue }
                // Parabolic interpolation of the peak position on log magnitude.
                let a = log(max(mag[k - 1], 1e-9)), b = log(m), c = log(max(mag[k + 1], 1e-9))
                let denom = a - 2 * b + c
                let delta = denom < 0 ? max(-0.5, min(0.5, 0.5 * (a - c) / denom)) : 0
                let freq = (Double(k) + Double(delta)) * binHz
                let midi = Int(Pitch.midi(forFrequency: freq).rounded())
                guard let key = Pitch.pianoKeyIndex(midi: midi) else { continue }
                // Microphones and small speakers capture the lowest octave poorly (and it is full of rumble).
                let weight: Float = freq < 50 ? 0.5 : 1
                let value = m.squareRoot() * weight
                if value > out[key] { out[key] = value }
            }
        }
        return out
    }
}
