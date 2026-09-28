import Foundation

/// Magnitude spectrum of real signals using an iterative radix-2 FFT.
///
/// Pure Swift so it runs on every platform; hot loops use unsafe buffers so the analyser stays cheap
/// even in unoptimised debug builds. Not thread-safe: use one instance per thread.
public final class RealFFT {
    public let size: Int
    public var binCount: Int { size / 2 + 1 }

    private let log2Size: Int
    private var cosTable: [Float]
    private var sinTable: [Float]
    private var bitReversed: [Int]
    private var window: [Float]
    private var re: [Float]
    private var im: [Float]

    /// - Parameter size: FFT length, a power of two >= 16.
    public init(size: Int) {
        precondition(size >= 16 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        var bits = 0
        while (1 << bits) < size { bits += 1 }
        log2Size = bits

        cosTable = (0..<size / 2).map { Float(cos(-2 * Double.pi * Double($0) / Double(size))) }
        sinTable = (0..<size / 2).map { Float(sin(-2 * Double.pi * Double($0) / Double(size))) }
        bitReversed = (0..<size).map { i in
            var r = 0, x = i
            for _ in 0..<bits { r = (r << 1) | (x & 1); x >>= 1 }
            return r
        }
        // Periodic Hann window.
        window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
        re = [Float](repeating: 0, count: size)
        im = [Float](repeating: 0, count: size)
    }

    /// Sum of the analysis window's samples (used to scale magnitudes to sine amplitude).
    public var windowSum: Float { window.reduce(0, +) }

    /// Hann-windowed magnitude spectrum of `input` (which must hold at least `size` samples; the
    /// first `size` are used). Returns `size / 2 + 1` magnitudes scaled so that a full-scale sine
    /// at a bin centre has magnitude ~1.
    public func magnitudes(_ input: UnsafeBufferPointer<Float>) -> [Float] {
        precondition(input.count >= size, "input shorter than FFT size")
        let n = size
        let scale = 2 / windowSum
        re.withUnsafeMutableBufferPointer { reP in
            im.withUnsafeMutableBufferPointer { imP in
                window.withUnsafeBufferPointer { w in
                    bitReversed.withUnsafeBufferPointer { rev in
                        for i in 0..<n {
                            reP[rev[i]] = input[i] * w[i]
                            imP[rev[i]] = 0
                        }
                    }
                }
                cosTable.withUnsafeBufferPointer { cosT in
                    sinTable.withUnsafeBufferPointer { sinT in
                        var half = 1
                        var tableStep = n / 2
                        while half < n {
                            let span = half * 2
                            var start = 0
                            while start < n {
                                var t = 0
                                for k in start..<(start + half) {
                                    let wr = cosT[t], wi = sinT[t]
                                    let j = k + half
                                    let xr = reP[j] * wr - imP[j] * wi
                                    let xi = reP[j] * wi + imP[j] * wr
                                    reP[j] = reP[k] - xr
                                    imP[j] = imP[k] - xi
                                    reP[k] += xr
                                    imP[k] += xi
                                    t += tableStep
                                }
                                start += span
                            }
                            half = span
                            tableStep /= 2
                        }
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: binCount)
        re.withUnsafeBufferPointer { reP in
            im.withUnsafeBufferPointer { imP in
                out.withUnsafeMutableBufferPointer { o in
                    for k in 0..<o.count {
                        o[k] = (reP[k] * reP[k] + imP[k] * imP[k]).squareRoot() * scale
                    }
                }
            }
        }
        return out
    }

    /// Convenience overload for arrays.
    public func magnitudes(_ input: [Float]) -> [Float] {
        input.withUnsafeBufferPointer { magnitudes($0) }
    }

    /// Centre frequency in Hz of bin `k`.
    public func frequency(ofBin k: Int, sampleRate: Double) -> Double {
        Double(k) * sampleRate / Double(size)
    }
}
