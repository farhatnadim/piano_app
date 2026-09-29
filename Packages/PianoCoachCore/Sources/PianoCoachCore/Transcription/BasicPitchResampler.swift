import Foundation

extension BasicPitch {
    /// Resamples mono audio to the model's 22050 Hz with a Kaiser-windowed sinc filter (flat to about 8.8 kHz,
    /// about 80 dB of alias rejection above 11 kHz).
    ///
    /// The output has `ceil(samples.count * 22050 / sourceRate)` samples, the length librosa (and therefore the
    /// Python reference) produces. Returns `samples` unchanged when `sourceRate` is already 22050, and no samples
    /// for a rate that is not positive and finite.
    public static func resample(_ samples: [Float], from sourceRate: Double) -> [Float] {
        guard sourceRate > 0, sourceRate.isFinite else { return [] }
        guard sourceRate != sampleRate else { return samples }
        guard !samples.isEmpty else { return [] }
        return PolyphaseResampler(sourceRate: sourceRate, targetRate: sampleRate).process(samples)
    }
}

/// Windowed-sinc resampler with a precomputed table of filter phases. For integral rates with a small common
/// divisor the phases are exact (e.g. 147 phases for 48 kHz -> 22050 Hz); otherwise the fractional position is
/// rounded to one of 4096 phases.
struct PolyphaseResampler {
    /// Zero crossings of the sinc on each side of the centre.
    static let zeroCrossings = 24.0
    /// Cutoff as a fraction of the lower Nyquist frequency.
    static let rolloff = 0.9
    /// Kaiser window shape (about 80 dB stopband).
    static let beta = 8.0
    static let maxExactPhases = 4096

    let sourceRate: Double
    let targetRate: Double
    /// Exact step as `interpolation` / `decimation` when both rates are integers with a small ratio.
    let interpolation: Int?
    let decimation: Int
    let phases: Int
    let taps: Int
    /// Taps before the centre sample: tap j multiplies input sample `base - leading + j`.
    let leading: Int
    /// `phases` rows of `taps` coefficients.
    let table: [Float]

    init(sourceRate: Double, targetRate: Double) {
        self.sourceRate = sourceRate
        self.targetRate = targetRate
        if let s = Self.integer(sourceRate), let t = Self.integer(targetRate) {
            let g = Self.gcd(s, t)
            if t / g <= Self.maxExactPhases {
                interpolation = t / g
                decimation = s / g
            } else {
                interpolation = nil
                decimation = 1
            }
        } else {
            interpolation = nil
            decimation = 1
        }
        phases = interpolation ?? Self.maxExactPhases

        // Cutoff in cycles per input sample and the filter's half-width in input samples.
        let cutoff = 0.5 * Self.rolloff * min(1, targetRate / sourceRate)
        let halfWidth = Self.zeroCrossings / (2 * cutoff)
        leading = Int(halfWidth.rounded(.up))
        taps = 2 * leading
        var table = [Float](repeating: 0, count: phases * taps)
        let i0Beta = Self.besselI0(Self.beta)
        var row = [Double](repeating: 0, count: taps)
        for phase in 0..<phases {
            let fraction = Double(phase) / Double(phases)
            var sum = 0.0
            for j in 0..<taps {
                // Distance from the output position to input sample (base - leading + 1 + j).
                let t = fraction + Double(leading - 1 - j)
                var h = 0.0
                let u = t / halfWidth
                if abs(u) < 1 {
                    let x = 2 * cutoff * t
                    let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
                    h = 2 * cutoff * sinc * Self.besselI0(Self.beta * (1 - u * u).squareRoot()) / i0Beta
                }
                row[j] = h
                sum += h
            }
            for j in 0..<taps { table[phase * taps + j] = Float(row[j] / sum) }
        }
        self.table = table
    }

    func process(_ input: [Float]) -> [Float] {
        let count = Int((Double(input.count) * (targetRate / sourceRate)).rounded(.up))
        var output = [Float](repeating: 0, count: count)
        let taps = taps
        let first = 1 - leading
        input.withUnsafeBufferPointer { x in
            table.withUnsafeBufferPointer { h in
                output.withUnsafeMutableBufferPointer { y in
                    var base = 0
                    var phase = 0
                    let step = sourceRate / targetRate
                    for o in 0..<count {
                        if let l = interpolation {
                            if o > 0 {
                                phase += decimation
                                base += phase / l
                                phase %= l
                            }
                        } else {
                            let position = Double(o) * step
                            base = Int(position.rounded(.down))
                            phase = Int(((position - Double(base)) * Double(phases)).rounded())
                            if phase == phases {
                                phase = 0
                                base += 1
                            }
                        }
                        y[o] = Self.dot(x, from: base + first, h, row: phase * taps, taps: taps)
                    }
                }
            }
        }
        return output
    }

    /// Sum of `taps` input samples starting at `start` (zero outside the input) times one table row.
    @inline(__always)
    private static func dot(_ x: UnsafeBufferPointer<Float>, from start: Int,
                            _ h: UnsafeBufferPointer<Float>, row: Int, taps: Int) -> Float {
        if start >= 0 && start + taps <= x.count {
            var a0: Float = 0, a1: Float = 0, a2: Float = 0, a3: Float = 0
            var j = 0
            while j + 4 <= taps {
                a0 += x[start + j] * h[row + j]
                a1 += x[start + j + 1] * h[row + j + 1]
                a2 += x[start + j + 2] * h[row + j + 2]
                a3 += x[start + j + 3] * h[row + j + 3]
                j += 4
            }
            while j < taps {
                a0 += x[start + j] * h[row + j]
                j += 1
            }
            return (a0 + a1) + (a2 + a3)
        }
        let lower = max(0, -start)
        let upper = min(taps, x.count - start)
        guard lower < upper else { return 0 }
        var sum: Float = 0
        for j in lower..<upper {
            sum += x[start + j] * h[row + j]
        }
        return sum
    }

    private static func integer(_ rate: Double) -> Int? {
        guard rate == rate.rounded(), rate >= 1, rate < 1e9 else { return nil }
        return Int(rate)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    /// Modified Bessel function of the first kind, order 0 (power series).
    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let q = x * x / 4
        var k = 1.0
        while term > sum * 1e-17 {
            term *= q / (k * k)
            sum += term
            k += 1
        }
        return sum
    }
}
