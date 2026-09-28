import Foundation

/// Tuning knobs for `OnsetAnalyzer`. Defaults suit a piano heard through a phone/laptop microphone.
public struct OnsetAnalyzerConfiguration: Sendable, Equatable {
    /// Sample rate of the mono audio fed to the analyser.
    public var sampleRate: Double
    /// FFT length for onset detection (~43 ms at 48 kHz).
    public var frameSize: Int
    /// Hop between onset-detection frames (~10.7 ms at 48 kHz).
    public var hopSize: Int
    /// FFT length for pitch features (~85 ms at 48 kHz).
    public var featureFrameSize: Int
    /// How long after the attack the pitch-feature window ends (lets the hammer noise settle).
    public var featureDelay: Double
    /// Onset threshold above the local mean of the detection function. Lower = more sensitive.
    public var threshold: Float
    /// Minimum time between two onsets; closer attacks are treated as one (e.g. a slightly rolled chord).
    public var minInterOnsetInterval: Double
    /// Frames quieter than this (dBFS RMS) never produce onsets.
    public var silenceFloorDB: Float
    /// Frames used for the moving-average part of the adaptive threshold.
    public var meanWindowFrames: Int
    /// Highest frequency considered, in Hz.
    public var maxFrequency: Double

    public init(sampleRate: Double, sensitivity: Float = 0.5) {
        self.sampleRate = sampleRate
        let scale = sampleRate / 48_000
        frameSize = RealFFTSizing.powerOfTwo(near: 2048 * scale)
        hopSize = max(64, Int((512 * scale).rounded()))
        featureFrameSize = RealFFTSizing.powerOfTwo(near: 4096 * scale)
        featureDelay = 0.06
        // sensitivity 0 -> threshold 0.9 (only clear attacks), 1 -> 0.15 (very sensitive).
        let s = max(0, min(1, sensitivity))
        threshold = 0.9 - 0.75 * s
        minInterOnsetInterval = 0.07
        silenceFloorDB = -62
        meanWindowFrames = 12
        maxFrequency = 5000
    }
}

enum RealFFTSizing {
    static func powerOfTwo(near value: Double) -> Int {
        let exponent = max(6, Int(log2(max(64, value)).rounded()))
        return 1 << exponent
    }
}

/// Streaming note-onset detector with pitch features.
///
/// Feed mono float samples of any chunk size with `process(_:)`; it returns the onsets whose pitch
/// features are complete. Onset detection uses a SuperFlux-style log-spectral flux (difference to a
/// frequency-max-filtered earlier frame) with an adaptive threshold and peak picking. For every onset
/// the analyser measures what *changed* in the spectrum ("new" energy after the attack minus the energy
/// just before it) so that sustained notes do not blur the notes just struck.
///
/// Not thread-safe; use from a single serial queue.
public final class OnsetAnalyzer {
    public let configuration: OnsetAnalyzerConfiguration

    /// Seconds of audio consumed since creation or `reset()`.
    public var clock: Double { Double(totalSamples) / configuration.sampleRate }
    /// Smoothed RMS level of the most recent audio, in dBFS (about -100 for silence).
    public private(set) var levelDB: Float = -100
    /// Latest onset-detection-function value (for meters/debugging).
    public private(set) var lastDetectionValue: Float = 0

    private let onsetFFT: RealFFT
    private let featureFFT: RealFFT
    private let featureMapper: SemitoneMapper
    private let fluxLowBin: Int
    private let fluxHighBin: Int

    // Ring buffer of recent samples, long enough for a feature window plus the pre-onset window.
    private var ring: [Float]
    private var ringWrite = 0
    private var totalSamples: Int64 = 0
    private var samplesSinceHop = 0

    // Onset detection state.
    private var previousLogSpectra: [[Float]] = []   // last few frames, newest last
    private var odfHistory: [Float] = []             // recent detection-function values
    private var odfTimes: [Double] = []
    private var longHistory: [Float] = []            // ~1 s of detection-function values for the median gate
    private var framesAnalyzed = 0
    private var frameLevels: [Float] = []
    private var lastOnsetTime: Double = -.infinity

    private struct PendingOnset {
        var time: Double
        var strength: Float
        var levelDB: Float
        var preOnsetEnergies: [Float]
        var readyAtSample: Int64
    }
    private var pending: [PendingOnset] = []

    public init(configuration: OnsetAnalyzerConfiguration) {
        self.configuration = configuration
        onsetFFT = RealFFT(size: configuration.frameSize)
        featureFFT = RealFFT(size: configuration.featureFrameSize)
        featureMapper = SemitoneMapper(fftSize: configuration.featureFrameSize,
                                       sampleRate: configuration.sampleRate,
                                       maxFrequency: configuration.maxFrequency)
        let binHz = configuration.sampleRate / Double(configuration.frameSize)
        fluxLowBin = max(1, Int(30 / binHz))
        fluxHighBin = min(configuration.frameSize / 2, Int(configuration.maxFrequency / binHz))
        let ringSize = configuration.featureFrameSize * 2 + configuration.frameSize
            + Int(configuration.featureDelay * configuration.sampleRate) + configuration.hopSize * 4
        ring = [Float](repeating: 0, count: ringSize)
    }

    public convenience init(sampleRate: Double, sensitivity: Float = 0.5) {
        self.init(configuration: OnsetAnalyzerConfiguration(sampleRate: sampleRate, sensitivity: sensitivity))
    }

    /// Clears all state and restarts the clock at zero.
    public func reset() {
        for i in ring.indices { ring[i] = 0 }
        ringWrite = 0
        totalSamples = 0
        samplesSinceHop = 0
        previousLogSpectra.removeAll()
        odfHistory.removeAll()
        odfTimes.removeAll()
        longHistory.removeAll()
        framesAnalyzed = 0
        frameLevels.removeAll()
        lastOnsetTime = -.infinity
        pending.removeAll()
        levelDB = -100
        lastDetectionValue = 0
    }

    /// Consumes mono samples and returns onsets whose features are now complete.
    public func process(_ samples: UnsafeBufferPointer<Float>) -> [NoteOnset] {
        var results: [NoteOnset] = []
        let hop = configuration.hopSize
        var index = 0
        while index < samples.count {
            let take = min(hop - samplesSinceHop, samples.count - index)
            for i in 0..<take {
                ring[ringWrite] = samples[index + i]
                ringWrite += 1
                if ringWrite == ring.count { ringWrite = 0 }
            }
            index += take
            samplesSinceHop += take
            totalSamples += Int64(take)
            if samplesSinceHop == hop {
                samplesSinceHop = 0
                analyzeFrame()
                results.append(contentsOf: completePendingOnsets())
            }
        }
        return results
    }

    public func process(_ samples: [Float]) -> [NoteOnset] {
        samples.withUnsafeBufferPointer { process($0) }
    }

    // MARK: - Frame analysis

    /// Copies the `count` samples that end `endOffset` samples before the newest sample.
    private func recentSamples(count: Int, endOffset: Int = 0) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        var start = ringWrite - endOffset - count
        while start < 0 { start += ring.count }
        ring.withUnsafeBufferPointer { r in
            out.withUnsafeMutableBufferPointer { o in
                var j = start
                for i in 0..<count {
                    o[i] = r[j]
                    j += 1
                    if j == r.count { j = 0 }
                }
            }
        }
        return out
    }

    private func analyzeFrame() {
        let n = configuration.frameSize
        let frame = recentSamples(count: n)

        // Level of the newest hop.
        var energy: Float = 0
        let hop = configuration.hopSize
        for i in (n - hop)..<n { energy += frame[i] * frame[i] }
        let rms = (energy / Float(hop)).squareRoot()
        let hopDB = 20 * log10(max(rms, 1e-5))
        levelDB = levelDB < -99 ? hopDB : 0.7 * levelDB + 0.3 * hopDB
        frameLevels.append(hopDB)
        if frameLevels.count > 8 { frameLevels.removeFirst() }

        // Log-compressed spectrum.
        let mags = onsetFFT.magnitudes(frame)
        var logSpec = [Float](repeating: 0, count: mags.count)
        for k in fluxLowBin...fluxHighBin { logSpec[k] = log(1 + 1000 * mags[k]) }

        // SuperFlux: compare with a frame two hops back, max-filtered over +/-1 bin (vibrato/tuning robust).
        var flux: Float = 0
        if let reference = previousLogSpectra.count >= 2 ? previousLogSpectra[previousLogSpectra.count - 2] : previousLogSpectra.first {
            for k in fluxLowBin...fluxHighBin {
                let ref = max(reference[max(0, k - 1)], reference[k], reference[min(reference.count - 1, k + 1)])
                let d = logSpec[k] - ref
                if d > 0 { flux += d }
            }
            flux /= Float(fluxHighBin - fluxLowBin + 1)
        }
        previousLogSpectra.append(logSpec)
        if previousLogSpectra.count > 3 { previousLogSpectra.removeFirst() }

        let frameTime = (Double(totalSamples) - Double(n) / 2) / configuration.sampleRate
        odfHistory.append(flux)
        odfTimes.append(frameTime)
        let keep = configuration.meanWindowFrames + 4
        if odfHistory.count > keep {
            odfHistory.removeFirst(odfHistory.count - keep)
            odfTimes.removeFirst(odfTimes.count - keep)
        }
        longHistory.append(flux)
        let longCount = max(16, Int(configuration.sampleRate / Double(configuration.hopSize)))
        if longHistory.count > longCount { longHistory.removeFirst(longHistory.count - longCount) }
        framesAnalyzed += 1
        lastDetectionValue = flux
        detectOnset()
    }

    /// Peak picking with one frame of look-ahead: frame `c = count-2` is an onset if it is the local
    /// maximum of its neighbourhood and exceeds the moving mean by the threshold.
    private func detectOnset() {
        let count = odfHistory.count
        // Skip the first frames: the flux against an all-zero history is meaningless.
        guard count >= 4, framesAnalyzed > 4 else { return }
        let c = count - 2
        let value = odfHistory[c]
        let lo = max(0, c - 3)
        for i in lo...(c + 1) where i != c {
            if odfHistory[i] > value || (i < c && odfHistory[i] == value) { return }
        }
        let meanLo = max(0, c - configuration.meanWindowFrames)
        var mean: Float = 0
        for i in meanLo..<c { mean += odfHistory[i] }
        mean /= Float(max(1, c - meanLo))
        // The flux is normalised per bin; typical piano attacks give 0.2 ... 3 (scale matches `threshold`).
        let scaled = value * 10
        guard scaled >= configuration.threshold + mean * 10 else { return }
        // Steady background noise has a flux floor of its own; demand a clear rise above it.
        let median = longHistory.sorted()[longHistory.count / 2]
        guard value >= 3 * median else { return }
        let maxLevel = frameLevels.max() ?? -100
        guard maxLevel > configuration.silenceFloorDB else { return }
        let time = odfTimes[c]
        guard time - lastOnsetTime >= configuration.minInterOnsetInterval else { return }
        lastOnsetTime = time

        // Energy just before the attack: a feature window ending ~10 ms before the onset frame.
        let sr = configuration.sampleRate
        let samplesSinceOnset = Int((Double(totalSamples) / sr - time) * sr)
        let preEnd = samplesSinceOnset + Int(0.01 * sr) + configuration.frameSize / 2
        let pre = recentSamples(count: configuration.featureFrameSize, endOffset: min(preEnd, ring.count - configuration.featureFrameSize))
        let preEnergies = featureMapper.keyEnergies(magnitudes: featureFFT.magnitudes(pre))

        let readyAt = Int64(((time + configuration.featureDelay) * sr).rounded(.up))
        pending.append(PendingOnset(time: time, strength: scaled - mean * 10, levelDB: maxLevel,
                                    preOnsetEnergies: preEnergies, readyAtSample: readyAt))
    }

    private func completePendingOnsets() -> [NoteOnset] {
        guard !pending.isEmpty else { return [] }
        var done: [NoteOnset] = []
        var remaining: [PendingOnset] = []
        for p in pending {
            guard totalSamples >= p.readyAtSample else { remaining.append(p); continue }
            let offset = Int(totalSamples - p.readyAtSample)
            let post = recentSamples(count: configuration.featureFrameSize,
                                     endOffset: min(offset, ring.count - configuration.featureFrameSize))
            let postEnergies = featureMapper.keyEnergies(magnitudes: featureFFT.magnitudes(post))
            var raw = [Float](repeating: 0, count: Pitch.pianoKeyCount)
            for k in 0..<raw.count {
                let newEnergy = max(0, postEnergies[k] - 0.9 * p.preOnsetEnergies[k])
                raw[k] = newEnergy + 0.15 * postEnergies[k]
            }
            done.append(NoteOnset(time: p.time, strength: p.strength, levelDB: p.levelDB,
                                  features: FeatureVector(semitones: raw)))
        }
        pending = remaining
        return done
    }
}
