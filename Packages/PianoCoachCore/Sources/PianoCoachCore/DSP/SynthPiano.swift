import Foundation

/// A tiny additive "piano" used to test the analyser and follower without a real instrument
/// (and by the app's demo mode). Each note has slightly inharmonic partials, a hammer-noise click,
/// a pitch-dependent exponential decay and a short damper release.
public enum SynthPiano {
    public struct Note: Sendable, Equatable {
        public var midi: Int
        /// Start time in seconds.
        public var start: Double
        /// Held duration in seconds (the damper falls after this).
        public var duration: Double
        /// 0...1
        public var velocity: Float

        public init(midi: Int, start: Double, duration: Double, velocity: Float = 0.7) {
            self.midi = midi
            self.start = start
            self.duration = duration
            self.velocity = velocity
        }
    }

    /// Renders `notes` into a mono buffer of `length` seconds.
    /// - Parameters:
    ///   - noiseLevel: amplitude of background white noise (room noise), e.g. 0.002.
    ///   - seed: seed for the deterministic noise generator.
    public static func render(_ notes: [Note], sampleRate: Double, length: Double,
                              noiseLevel: Float = 0, seed: UInt64 = 1) -> [Float] {
        let count = max(0, Int(length * sampleRate))
        var out = [Float](repeating: 0, count: count)
        var rng = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        func noise() -> Float {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            return Float(Double(rng % 2_000_001) / 1_000_000 - 1)
        }
        let release = 0.08
        for note in notes {
            let f0 = Pitch.frequency(midi: note.midi)
            let startIndex = Int(note.start * sampleRate)
            guard startIndex < count else { continue }
            let decayTime = 2.5 * pow(261.6 / f0, 0.45)       // low notes ring longer
            let endTime = note.duration + release
            let endIndex = min(count, startIndex + Int(endTime * sampleRate))
            let amp = 0.18 * note.velocity
            var partials: [(freq: Double, gain: Float, decay: Double)] = []
            for h in 1...10 {
                let hd = Double(h)
                let f = hd * f0 * (1 + 0.0004 * hd * hd).squareRoot()
                if f > sampleRate * 0.45 || f > 8000 { break }
                partials.append((f, Float(1 / pow(hd, 1.1)), decayTime / (1 + 0.35 * (hd - 1))))
            }
            for i in startIndex..<endIndex {
                let t = Double(i - startIndex) / sampleRate
                let attack = min(1, t / 0.004)
                let damper = t > note.duration ? max(0, 1 - (t - note.duration) / release) : 1
                var s: Float = 0
                for p in partials {
                    s += p.gain * Float(exp(-t / p.decay) * sin(2 * Double.pi * p.freq * t))
                }
                // Hammer "thump": a few milliseconds of decaying noise.
                if t < 0.012 { s += 0.25 * noise() * Float(1 - t / 0.012) }
                out[i] += amp * Float(attack * damper) * s
            }
        }
        if noiseLevel > 0 {
            for i in 0..<count { out[i] += noiseLevel * noise() }
        }
        return out
    }
}
