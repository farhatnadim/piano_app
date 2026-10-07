import Foundation

/// Tuning knobs for `PianoKeyListener`. Defaults suit a piano heard through a phone, tablet or laptop
/// microphone.
public struct PianoKeyListenerConfiguration: Sendable, Equatable {
    /// Sample rate of the mono audio fed to the listener.
    public var sampleRate: Double
    /// FFT length (~170 ms at 48 kHz): long enough to tell neighbouring semitones apart.
    public var fftSize: Int
    /// Hop between analyses (~10.7 ms at 48 kHz).
    public var hopSize: Int
    /// Highest frequency listened to, in Hz.
    public var maxFrequency: Double = 5000
    /// Half-width of each key's band, in cents.
    public var bandCents: Double = 35
    /// A spectral peak must stand this far above the spectrum around it (dB).
    public var peakProminenceDB: Float = 9
    /// A band whose level jumps this much (dB) starts a strike...
    public var triggerRiseDB: Float = 7
    /// ...if its peak stands this far above the spectrum around it (dB).
    public var triggerProminenceDB: Float = 12
    /// A strike is decided once its bands stop rising, after at least this many hops...
    public var minStrikeHops = 6
    /// ...and at most this many...
    public var maxStrikeHops = 18
    /// ...or, while a low note's pitch is still settling, this many.
    public var maxStrikeHopsLow = 26
    /// Bands rising less than this over two hops have settled (dB).
    public var settleDB: Float = 1
    /// Hops (at the band's loudest) over which the pitch must hold steady.
    public var steadyHops = 6

    /// Expected keys: the band must have gained this much (dB)...
    public var expectedGainDB: Float = 4.5
    /// ...its pitch may wander this much (cents)...
    public var expectedWanderCents: Float = 20
    /// ...sit this far from the key (cents)...
    public var expectedOffsetCents: Float = 40
    /// ...and must stand out this far (dB).
    public var expectedProminenceDB: Float = 14
    /// Any other key (a wrong note) must pass stricter versions of the same checks.
    public var otherGainDB: Float = 10
    public var otherWanderCents: Float = 12
    public var otherOffsetCents: Float = 30
    public var otherProminenceDB: Float = 20
    /// Nothing quieter than this counts (dBFS, sine amplitude).
    public var floorDB: Float = -80
    /// A wrong note may be at most this much quieter than the piano's notes so far (dB).
    public var otherBelowPianoDB: Float = 18
    /// Further notes in a strike need this fraction of the strongest note's harmonic strength.
    public var salienceRatio: Float = 0.25
    /// A real octave played with a lower note is at most this much quieter than it (dB).
    public var octaveMarginDB: Float = 4
    /// Attacks are timed on a partial at least this high (Hz), where neighbouring notes don't blur them.
    public var timingFrequency: Double = 700

    /// Seconds over which the piano's tuning is measured...
    public var tuningTime: Double = 1
    /// ...from peaks that agree on it at least this much (0...1).
    public var tuningConcentration: Double = 0.6
    /// Seconds over which talking (tonal sound off the piano's pitches) is measured...
    public var talkTime: Double = 0.4
    /// ...it is talking when this share of the tonal energy is off the keys...
    public var talkShare: Double = 0.18
    /// ...more than this many cents from the nearest key.
    public var offKeyCents: Double = 30
    /// Off-key sound is remembered this long (s).
    public var offKeyMemory: Double = 0.5
    /// During talking an expected key must be this much louder than the voice (dB)...
    public var overTalkDB: Float = 6
    /// ...and a wrong note always this much louder than recent off-key sound (dB).
    public var wrongOverOffKeyDB: Float = 10

    /// - Parameter sensitivity: 0...1; higher hears softer playing of the expected notes (wrong notes always
    ///   need clear evidence).
    public init(sampleRate: Double, sensitivity: Float = 0.5) {
        self.sampleRate = sampleRate
        let scale = sampleRate / 48_000
        fftSize = RealFFTSizing.powerOfTwo(near: 8192 * scale)
        hopSize = max(64, Int((512 * scale).rounded()))
        let s = max(0, min(1, sensitivity))
        floorDB = -70 - 20 * s
        expectedProminenceDB = 17 - 6 * s
        expectedGainDB = 6 - 3 * s
    }
}

/// Listens for piano keys through a microphone, in narrow bands around the pitches of the 88 keys.
///
/// Each key has a band a third of a semitone wide around its pitch (and around its overtones), tuned to the
/// piano being played. Sounds that aren't notes — talking, clapping, a fan, traffic — spread their energy
/// across and between the keys' pitches instead of piling it up right on them, so they don't register.
///
/// Every hop the spectrum's sharp peaks are sorted into the bands. A band that jumps in level starts a
/// *strike*; once its bands have settled, the strike is decided from what each band gained: every key's
/// harmonic strength (its overtones' gains, weighted), and greedily the strongest key that passes the checks
/// (steady pitch, in tune, standing out, loud enough), its overtones then explained away. The keys the game
/// expects get looser checks than the others, which become wrong notes.
///
/// Talking is recognised by its tonal sound falling between the piano's keys; while someone talks no wrong
/// notes are reported and expected keys must be clearly louder than the voice. The piano's own tuning is
/// learned from its notes (an old piano may be a quarter of a semitone flat).
///
/// Not thread-safe; use from a single serial queue.
public final class PianoKeyListener {
    /// Keys heard in one strike.
    public struct Heard: Sendable, Equatable {
        /// When they were struck: seconds of audio consumed since creation or `reset()`.
        public var time: Double
        /// The expected keys heard (MIDI numbers, ascending), or for a wrong note the one key most likely played.
        public var keys: [Int]
        /// No expected key was heard: `keys` is a wrong note.
        public var isWrong: Bool
        /// Level of the loudest key heard (dBFS, sine amplitude).
        public var levelDB: Float

        public init(time: Double, keys: [Int], isWrong: Bool, levelDB: Float) {
            self.time = time
            self.keys = keys
            self.isWrong = isWrong
            self.levelDB = levelDB
        }
    }

    public let configuration: PianoKeyListenerConfiguration
    /// The keys (MIDI numbers) the game is waiting for now. Set it before each `process` call.
    public var expectedKeys: Set<Int> = []

    /// Seconds of audio consumed since creation or `reset()`.
    public var clock: Double { Double(totalSamples) / configuration.sampleRate }
    /// Smoothed RMS level of the most recent audio, in dBFS (about -100 for silence).
    public private(set) var levelDB: Float = -100
    /// The piano's tuning relative to A = 440 Hz, in cents (learned from what is heard).
    public private(set) var tuningCents: Double = 0
    /// Whether someone seems to be talking (or singing off the piano's pitches) right now.
    public var hearsTalking: Bool {
        talkEnergy.total > 1e-6 && talkEnergy.off / talkEnergy.total >= configuration.talkShare
    }

    // MARK: Fixed tables

    private static let partialCount = 8
    private static let inharmonicity = 0.0003
    /// Cents of partial h (1...8) above the fundamental, slightly stretched like a piano string's.
    private static let partialCents: [Double] = (1...partialCount).map { centsOfPartial($0) }
    /// Semitone step of each partial: 0, 12, 19, 24, 28, 31, 34, 36.
    private static let partialStep: [Int] = partialCents.map { Int(($0 / 100).rounded()) }
    /// Cents of each partial from its band's centre.
    private static let partialOffset: [Double] = zip(partialCents, partialStep).map { $0 - 100 * Double($1) }
    /// Cents of partials 2...16 (for recognising overtones of a key still sounding).
    private static let overtoneCents: [Double] = (2...16).map { centsOfPartial($0) }
    private static let partialWeight: [Double] = (1...partialCount).map { 1 / pow(Double($0), 0.6) }

    private static func centsOfPartial(_ h: Int) -> Double {
        let hd = Double(h)
        return 1200 * log2(hd * (1 + inharmonicity * hd * hd).squareRoot() / (1 + inharmonicity).squareRoot())
    }

    private let fft: RealFFT
    private let binHz: Double
    private let minBin: Int
    private let maxBin: Int
    /// Band b is MIDI `Pitch.lowestPianoMIDI + b` (A0 up to `maxFrequency`); band k is also key k's own band.
    private let bandCount: Int
    private let backgroundLow: [Int]
    private let backgroundHigh: [Int]
    private let warmUpHops: Int
    private let offKeyMemoryHops: Int

    // MARK: State

    private var ring: [Float]
    private var ringWrite = 0
    private var totalSamples: Int64 = 0
    private var samplesSinceHop = 0
    private var frameIndex = 0
    private var fftInput: [Float]

    /// Band levels of the last 13 hops, oldest first (rows of `bandCount`).
    private var history: [[Float]]
    /// After a strike, its bands may only start another one after dipping (dB).
    private var postFloor: [Float]
    private var strike: Strike?
    private var tuningSums = (cos: 0.0, sin: 0.0, weight: 0.0)
    private var talkEnergy = (off: 0.0, total: 0.0)
    private var offKeyHistory: [Float] = []
    /// When each key was last struck.
    private var keyOnset: [Int: Double] = [:]
    /// Keys struck recently: onset and level (their overtones aren't new notes).
    private var sounding: [Int: (onset: Double, level: Float)] = [:]
    /// Typical level of the expected notes heard (dB).
    private var pianoLevel: Float?

    private struct BandFrame {
        var level: [Float]
        var offset: [Float]      // cents of the band's peak from its centre (0 when absent)
        var prominence: [Float]  // dB (0 when absent)
        var present: [Bool]
    }

    private struct Strike {
        var start: Int
        var base: [Float]
        var frames: [BandFrame] = []
        var offKeyDB: Float = -200
        var talking = false
    }

    public init(configuration: PianoKeyListenerConfiguration) {
        self.configuration = configuration
        let n = configuration.fftSize
        fft = RealFFT(size: n)
        binHz = configuration.sampleRate / Double(n)
        let top = Int((69 + 12 * log2(configuration.maxFrequency / 440)).rounded(.down))
        bandCount = max(Pitch.pianoKeyCount, top - Pitch.lowestPianoMIDI + 1)
        maxBin = min(n / 2 - 2, Int(configuration.maxFrequency * 1.03 / binHz))
        minBin = max(2, Int(25 / binHz))
        var low = [Int](repeating: 0, count: n / 2 + 1)
        var high = [Int](repeating: 0, count: n / 2 + 1)
        for b in 0...(n / 2) {
            let w = max(8, Int((Double(b) * (pow(2, 3.0 / 12) - 1)).rounded()))
            low[b] = min(max(b - w, 1), n / 2)
            high[b] = min(max(b + w, 1), n / 2)
        }
        backgroundLow = low
        backgroundHigh = high
        warmUpHops = n / configuration.hopSize + 12
        offKeyMemoryHops = max(1, Int(configuration.offKeyMemory * configuration.sampleRate / Double(configuration.hopSize)))
        ring = [Float](repeating: 0, count: max(n, Int(0.6 * configuration.sampleRate)) + configuration.hopSize)
        fftInput = [Float](repeating: 0, count: n)
        history = Array(repeating: [Float](repeating: -200, count: bandCount), count: 13)
        postFloor = [Float](repeating: -200, count: bandCount)
    }

    public convenience init(sampleRate: Double, sensitivity: Float = 0.5) {
        self.init(configuration: PianoKeyListenerConfiguration(sampleRate: sampleRate, sensitivity: sensitivity))
    }

    /// Clears all state (including the learned tuning) and restarts the clock at zero.
    public func reset() {
        for i in ring.indices { ring[i] = 0 }
        ringWrite = 0
        totalSamples = 0
        samplesSinceHop = 0
        frameIndex = 0
        history = Array(repeating: [Float](repeating: -200, count: bandCount), count: 13)
        postFloor = [Float](repeating: -200, count: bandCount)
        strike = nil
        tuningSums = (0, 0, 0)
        talkEnergy = (0, 0)
        offKeyHistory = []
        keyOnset = [:]
        sounding = [:]
        pianoLevel = nil
        tuningCents = 0
        levelDB = -100
    }

    /// Consumes mono samples and returns the strikes decided meanwhile.
    public func process(_ samples: UnsafeBufferPointer<Float>) -> [Heard] {
        var results: [Heard] = []
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
                results.append(contentsOf: analyzeHop())
            }
        }
        return results
    }

    public func process(_ samples: [Float]) -> [Heard] {
        samples.withUnsafeBufferPointer { process($0) }
    }

    // MARK: - Spectrum

    /// Copies the `count` newest samples, oldest first.
    private func copyRecent(into out: inout [Float], count: Int) {
        var j = ringWrite - count
        while j < 0 { j += ring.count }
        ring.withUnsafeBufferPointer { r in
            out.withUnsafeMutableBufferPointer { o in
                for i in 0..<count {
                    o[i] = r[j]
                    j += 1
                    if j == r.count { j = 0 }
                }
            }
        }
    }

    private struct Peaks {
        var cents: [Double] = []     // 1200 * log2(f / 440), ascending
        var height: [Float] = []
        var prominence: [Float] = []  // linear ratio
    }

    private func bandFrame() -> BandFrame {
        let n = configuration.fftSize
        copyRecent(into: &fftInput, count: n)
        let mag = fft.magnitudes(fftInput)
        let count = mag.count
        var logm = [Float](repeating: 0, count: count)
        var prefix = [Double](repeating: 0, count: count + 1)
        for k in 0..<count {
            logm[k] = log(max(mag[k], 1e-10))
            prefix[k + 1] = prefix[k] + Double(logm[k])
        }
        func background(_ k: Int) -> Float {
            let lo = backgroundLow[k], hi = backgroundHigh[k]
            return Float(exp((prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)))
        }

        // Sharp peaks that stand out from their surroundings, with interpolated frequency and height.
        var peaks = Peaks()
        let peakRatio = pow(Float(10), configuration.peakProminenceDB / 20)
        if minBin <= maxBin {
            for k in minBin...maxBin {
                let m = mag[k]
                guard m > mag[k - 1], m >= mag[k + 1] else { continue }
                let bg = background(k)
                guard m > bg * peakRatio else { continue }
                let a = logm[k - 1], b = logm[k], c = logm[k + 1]
                let den = a - 2 * b + c
                let delta: Float = den < 0 ? max(-0.5, min(0.5, 0.5 * (a - c) / den)) : 0
                let freq = (Double(k) + Double(delta)) * binHz
                let height = exp(b - 0.25 * (a - c) * delta)
                peaks.cents.append(1200 * log2(freq / 440))
                peaks.height.append(height)
                peaks.prominence.append(height / bg)
            }
        }
        updateTonalStatistics(peaks)

        // Bands: the level is the strongest magnitude in the band; the peak (if any) gives pitch and prominence.
        var frame = BandFrame(level: [Float](repeating: -200, count: bandCount),
                              offset: [Float](repeating: 0, count: bandCount),
                              prominence: [Float](repeating: 0, count: bandCount),
                              present: [Bool](repeating: false, count: bandCount))
        var first = 0
        for s in 0..<bandCount {
            let centreCents = Double(Pitch.lowestPianoMIDI + s - 69) * 100 + tuningCents
            let centre = 440 * pow(2, centreCents / 1200)
            let tol = max(configuration.bandCents, 1200 * log2(1 + 0.6 * binHz / centre))
            let lo = min(max(Int((centre * pow(2, -tol / 1200) / binHz).rounded(.down)), 1), count - 2)
            let hi = min(max(Int((centre * pow(2, tol / 1200) / binHz).rounded(.up)), 1), count - 2)
            var top: Float = 0
            if lo <= hi { for k in lo...hi { top = max(top, mag[k]) } }
            frame.level[s] = Self.decibels(top)
            while first < peaks.cents.count, peaks.cents[first] < centreCents - tol { first += 1 }
            var best = -1
            var j = first
            while j < peaks.cents.count, peaks.cents[j] <= centreCents + tol {
                if best < 0 || peaks.height[j] > peaks.height[best] { best = j }
                j += 1
            }
            if best >= 0 {
                frame.offset[s] = Float(peaks.cents[best] - centreCents)
                frame.prominence[s] = Self.decibels(peaks.prominence[best])
                frame.present[s] = true
            }
        }
        return frame
    }

    /// Learns the piano's tuning (peaks that agree on an offset from A440) and measures talking (tonal
    /// energy between the keys).
    private func updateTonalStatistics(_ peaks: Peaks) {
        let hopSeconds = Double(configuration.hopSize) / configuration.sampleRate
        let minProminence = pow(Float(10), Float(12) / 20)
        var sumCos = 0.0, sumSin = 0.0, sumWeight = 0.0
        var selected: [(cents: Double, weight: Double)] = []
        let lowCents = 1200 * log2(80.0 / 440), highCents = 1200 * log2(2500.0 / 440)
        for i in peaks.cents.indices where peaks.cents[i] > lowCents && peaks.cents[i] < highCents
            && peaks.prominence[i] >= minProminence {
            let w = Double(peaks.height[i])
            let angle = 2 * Double.pi * peaks.cents[i] / 100
            sumCos += w * cos(angle)
            sumSin += w * sin(angle)
            sumWeight += w
            selected.append((peaks.cents[i], w))
        }
        let a = 1 - exp(-hopSeconds / configuration.tuningTime)
        tuningSums = ((1 - a) * tuningSums.cos + a * sumCos, (1 - a) * tuningSums.sin + a * sumSin,
                      (1 - a) * tuningSums.weight + a * sumWeight)
        if tuningSums.weight > 1e-6 {
            let concentration = (tuningSums.cos * tuningSums.cos + tuningSums.sin * tuningSums.sin).squareRoot()
                / tuningSums.weight
            if concentration >= configuration.tuningConcentration {
                let target = atan2(tuningSums.sin, tuningSums.cos) * 100 / (2 * Double.pi)
                let step = Self.wrapCents(target - tuningCents)
                tuningCents = max(-50, min(50, tuningCents + 0.05 * step))
            }
        }
        var off = 0.0, loudestOff = 0.0
        for p in selected where abs(Self.wrapCents(p.cents - tuningCents)) > configuration.offKeyCents {
            off += p.weight
            loudestOff = max(loudestOff, p.weight)
        }
        let b = 1 - exp(-hopSeconds / configuration.talkTime)
        talkEnergy = ((1 - b) * talkEnergy.off + b * off, (1 - b) * talkEnergy.total + b * sumWeight)
        offKeyHistory.append(loudestOff > 0 ? Self.decibels(Float(loudestOff)) : -200)
        if offKeyHistory.count > offKeyMemoryHops { offKeyHistory.removeFirst(offKeyHistory.count - offKeyMemoryHops) }
    }

    /// `cents` folded into -50..<50.
    private static func wrapCents(_ cents: Double) -> Double {
        let x = cents + 50
        return x - 100 * (x / 100).rounded(.down) - 50
    }

    private static func decibels(_ x: Float) -> Float { 20 * log10(max(x, 1e-10)) }

    // MARK: - Per hop

    private func analyzeHop() -> [Heard] {
        updateLevel()
        let frame = bandFrame()
        history.removeFirst()
        history.append(frame.level)
        let f = frameIndex
        frameIndex += 1
        guard f >= warmUpHops else { return [] }

        var base = [Float](repeating: -200, count: bandCount)
        for s in 0..<bandCount {
            postFloor[s] = min(postFloor[s], frame.level[s])
            var low = Float.infinity
            for row in 0..<(history.count - 1) { low = min(low, history[row][s]) }
            base[s] = max(low, postFloor[s])
        }
        if strike == nil {
            for s in 0..<bandCount where frame.present[s] && frame.prominence[s] >= configuration.triggerProminenceDB
                && frame.level[s] - base[s] >= configuration.triggerRiseDB {
                strike = Strike(start: f, base: base)
                break
            }
        }
        guard var current = strike else { return [] }
        current.frames.append(frame)
        current.offKeyDB = max(current.offKeyDB, offKeyHistory.max() ?? -200)
        current.talking = current.talking || hearsTalking
        strike = current
        let age = f - current.start
        guard age >= configuration.maxStrikeHops || (age >= configuration.minStrikeHops && settled(current)) else {
            return []
        }
        return decide(frame: f, levelNow: frame.level, final: age >= configuration.maxStrikeHopsLow) ?? []
    }

    private func updateLevel() {
        let hop = configuration.hopSize
        var j = ringWrite - hop
        while j < 0 { j += ring.count }
        var energy: Float = 0
        for _ in 0..<hop {
            energy += ring[j] * ring[j]
            j += 1
            if j == ring.count { j = 0 }
        }
        let hopDB = Self.decibels((energy / Float(hop)).squareRoot())
        levelDB = levelDB < -99 ? hopDB : 0.7 * levelDB + 0.3 * hopDB
    }

    /// The bands that gained in the strike have stopped rising.
    private func settled(_ strike: Strike) -> Bool {
        guard strike.frames.count >= 3 else { return false }
        let now = strike.frames[strike.frames.count - 1]
        let before = strike.frames[strike.frames.count - 3]
        var anyPresent = false
        var strongest: Float = -.infinity
        for s in 0..<bandCount where now.level[s] - strike.base[s] >= 6 {
            if now.present[s] { anyPresent = true }
            strongest = max(strongest, now.level[s])
        }
        guard anyPresent else { return true }
        for s in 0..<bandCount where now.level[s] - strike.base[s] >= 6 && now.level[s] >= strongest - 30 {
            if now.level[s] - before.level[s] >= configuration.settleDB { return false }
        }
        return true
    }

    // MARK: - Deciding a strike

    private enum Verdict: Equatable {
        case heard, outOfRange, noGain, gone, short, weak, wanders, offPitch, faint, quiet, overtone, talking,
             underTalk, pureTone

        /// Still settling: a low note may be worth a longer look.
        var mayClearUp: Bool { self == .wanders || self == .gone || self == .short }
    }

    /// Everything measured over a strike.
    private struct Evidence {
        var level: [[Float]]      // [frame][band]
        var offset: [[Float]]
        var prominence: [[Float]]
        var present: [[Bool]]
        var base: [Float]
        var peak: [Float]         // loudest level while the band's peak was there (-200 if never)
        var gain: [Double]        // amplitude of the energy the band gained
        var offKeyDB: Float
        var talking: Bool
    }

    private func evidence(of strike: Strike) -> Evidence {
        var ev = Evidence(level: strike.frames.map(\.level), offset: strike.frames.map(\.offset),
                          prominence: strike.frames.map(\.prominence), present: strike.frames.map(\.present),
                          base: strike.base, peak: [Float](repeating: -200, count: bandCount),
                          gain: [Double](repeating: 0, count: bandCount), offKeyDB: strike.offKeyDB,
                          talking: strike.talking)
        for s in 0..<bandCount {
            var peak: Float = -200
            for t in ev.level.indices where ev.present[t][s] { peak = max(peak, ev.level[t][s]) }
            ev.peak[s] = peak
            guard peak > -200 else { continue }
            let power = pow(10, Double(peak) / 10) - pow(10, Double(strike.base[s]) / 10)
            ev.gain[s] = power > 0 ? power.squareRoot() : 0
        }
        return ev
    }

    private static func keyFrequency(_ k: Int) -> Double { 440 * pow(2, Double(k + Pitch.lowestPianoMIDI - 69) / 12) }

    private func salience(_ remaining: [Double]) -> [Double] {
        (0..<Pitch.pianoKeyCount).map { k in
            var s = 0.0
            for h in 0..<Self.partialCount {
                let b = k + Self.partialStep[h]
                if b < bandCount { s += remaining[b] * Self.partialWeight[h] }
            }
            // A key above ~150 Hz whose own band gained nothing is very unlikely.
            if Self.keyFrequency(k) > 150 && remaining[k] <= 0 { s *= 0.3 }
            return s
        }
    }

    private func decide(frame f: Int, levelNow: [Float], final: Bool) -> [Heard]? {
        guard let current = strike else { return [] }
        let ev = evidence(of: current)
        let now = Double(f + 1) * Double(configuration.hopSize) / configuration.sampleRate
        let expected = Set(expectedKeys.compactMap { Pitch.pianoKeyIndex(midi: $0) })

        // The most salient keys, strongest first, each explaining its overtones away.
        var remaining = ev.gain
        var accepted: [(key: Int, main: Int, salience: Double)] = []
        var firstVerdict: (key: Int, verdict: Verdict)?
        var strongest: Double?
        for _ in 0..<6 {
            let s = salience(remaining)
            guard let k = s.indices.max(by: { s[$0] < s[$1] }), s[k] > 0 else { break }
            if let strongest, s[k] < Double(configuration.salienceRatio) * strongest { break }
            strongest = strongest ?? s[k]
            let (verdict, main) = check(k, expected: expected.contains(k), ev, now: now)
            if firstVerdict == nil { firstVerdict = (k, verdict) }
            if verdict == .heard { accepted.append((k, main, s[k])) }
            for h in 0..<Self.partialCount where k + Self.partialStep[h] < bandCount {
                remaining[k + Self.partialStep[h]] = 0
            }
        }
        if !final, let first = firstVerdict, first.key + Pitch.lowestPianoMIDI < 63, first.verdict.mayClearUp {
            return nil   // a low note: its pitch needs a longer look
        }
        strike = nil

        // A second look at the expected keys (an octave played with a lower note, a quieter chord note).
        var heardExpected = accepted.map(\.key).filter { expected.contains($0) }
        for k in expected.sorted() where !heardExpected.contains(k) {
            let (verdict, main) = check(k, expected: true, ev, now: now)
            if verdict == .heard {
                accepted.append((k, main, 0))
                heardExpected.append(k)
            }
        }
        // Don't let the accepted keys' bands start another strike until they dip.
        for (k, _, _) in accepted {
            for h in 0..<Self.partialCount {
                let b = k + Self.partialStep[h]
                if b < bandCount && ev.peak[b] - ev.base[b] > 3 { postFloor[b] = max(postFloor[b], levelNow[b] + 1) }
            }
        }
        guard !accepted.isEmpty else { return [] }

        var kept: [(key: Int, main: Int, salience: Double)] = []
        for candidate in accepted {
            let k = candidate.key
            let onset = onsetTime(of: k, main: candidate.main, ev, frame: f, now: now)
            if let previous = keyOnset[k], abs(onset - previous) < 0.05 { continue }   // the same attack again
            let isExpected = expected.contains(k)
            var lowerLevel: Float?
            for (j, note) in sounding where j < k - 11 && abs(onset - note.onset) < 0.03 {
                lowerLevel = max(lowerLevel ?? -200, ev.peak[j])
            }
            for other in kept where other.key < k - 11 && abs(onset - (keyOnset[other.key] ?? -9)) < 0.03 {
                lowerLevel = max(lowerLevel ?? -200, ev.peak[other.key])
            }
            if let lowerLevel {
                // Starting with a lower note: its overtone, unless it's expected and about as loud (an octave).
                guard isExpected, ev.peak[k] >= lowerLevel - configuration.octaveMarginDB else { continue }
            }
            kept.append(candidate)
            keyOnset[k] = onset
            sounding[k] = (onset, ev.peak[k + Self.partialStep[candidate.main]])
        }
        sounding = sounding.filter { now - $0.value.onset < 2 }
        heardExpected = heardExpected.filter { k in kept.contains { $0.key == k } }
        guard !kept.isEmpty else { return [] }

        if !heardExpected.isEmpty {
            var level: Float = -200
            for (k, main, _) in kept where heardExpected.contains(k) {
                let lv = ev.peak[k + Self.partialStep[main]]
                level = max(level, lv)
                pianoLevel = pianoLevel.map { max(lv, 0.8 * $0 + 0.2 * lv) } ?? lv
            }
            let onset = heardExpected.compactMap { keyOnset[$0] }.min() ?? now
            return [Heard(time: onset, keys: heardExpected.sorted().map { $0 + Pitch.lowestPianoMIDI },
                          isWrong: false, levelDB: level)]
        }
        guard let wrong = kept.max(by: { $0.salience < $1.salience }) else { return [] }
        return [Heard(time: keyOnset[wrong.key] ?? now, keys: [wrong.key + Pitch.lowestPianoMIDI], isWrong: true,
                      levelDB: ev.peak[wrong.key + Self.partialStep[wrong.main]])]
    }

    /// Checks key `k` (index from A0) against the strike's evidence. Returns the verdict and the partial
    /// (0-based) it was judged by.
    private func check(_ k: Int, expected isExpected: Bool, _ ev: Evidence, now: Double) -> (Verdict, Int) {
        let c = configuration
        let steps = (0..<4).filter { k + Self.partialStep[$0] < bandCount }
        guard !steps.isEmpty else { return (.outOfRange, 0) }
        let f0 = Self.keyFrequency(k)
        // Above ~150 Hz a piano note always has its fundamental; lower ones are judged by their strongest partial.
        let main = f0 >= 150 ? 0 : steps.prefix(3).max { ev.gain[k + Self.partialStep[$0]] < ev.gain[k + Self.partialStep[$1]] }!
        let b = k + Self.partialStep[main]
        guard ev.gain[b] > 0 else { return (.noGain, main) }
        let seen = ev.present.map { $0[b] }
        guard seen.suffix(4).filter({ $0 }).count >= 3 else { return (.gone, main) }
        var loudest: Float = -200
        for t in seen.indices where seen[t] { loudest = max(loudest, ev.level[t][b]) }
        let rows = seen.indices.filter { seen[$0] && ev.level[$0][b] >= loudest - 3 }.suffix(c.steadyHops)
        guard rows.count >= 2 else { return (.short, main) }
        let offsets = rows.map { Double(ev.offset[$0][b]) - Self.partialOffset[main] }
        let wander = Float(offsets.max()! - offsets.min()!)
        let offPitch = Float(abs(Self.median(offsets)))
        let gain = loudest - ev.base[b]
        let prominence = ev.prominence.map { $0[b] }.max() ?? 0
        if gain < (isExpected ? c.expectedGainDB : c.otherGainDB) { return (.weak, main) }
        if wander > (isExpected ? c.expectedWanderCents : c.otherWanderCents) { return (.wanders, main) }
        if offPitch > (isExpected ? c.expectedOffsetCents : c.otherOffsetCents) { return (.offPitch, main) }
        if prominence < (isExpected ? c.expectedProminenceDB : c.otherProminenceDB) { return (.faint, main) }
        if loudest < c.floorDB { return (.quiet, main) }
        if !isExpected, overtoneOfSounding(k, level: loudest, now: now) { return (.overtone, main) }
        if ev.talking {
            if !isExpected { return (.talking, main) }
            if loudest < ev.offKeyDB + c.overTalkDB { return (.underTalk, main) }
        }
        if !isExpected {
            if loudest < ev.offKeyDB + c.wrongOverOffKeyDB { return (.underTalk, main) }
            if let pianoLevel, loudest < pianoLevel - c.otherBelowPianoDB { return (.quiet, main) }
            if f0 < 1000 {
                // A piano note has overtones; a beep or a whistle doesn't.
                let partials = steps.filter { ev.gain[k + Self.partialStep[$0]] > 0.05 * ev.gain[b] }.count
                if partials < 2 { return (.pureTone, main) }
            }
        }
        return (.heard, main)
    }

    /// Whether key `k` sits on an overtone of a key struck shortly before (or is a much quieter key above it).
    private func overtoneOfSounding(_ k: Int, level: Float, now: Double) -> Bool {
        for (j, note) in sounding where now - note.onset <= 1 && Double(k - j) >= 11.5 {
            let d = Double(k - j) * 100
            if Self.overtoneCents.contains(where: { abs(d - $0) <= 45 }) { return true }
            if now - note.onset < 0.6 && level < note.level - 10 { return true }
        }
        return false
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    // MARK: - Onset time

    /// When key `k` was struck: where the fine-time envelope of one of its partials rose (falls back to the
    /// hop its band jumped in).
    private func onsetTime(of k: Int, main: Int, _ ev: Evidence, frame f: Int, now: Double) -> Double {
        var main = main
        let f0 = Self.keyFrequency(k)
        if f0 * Double(main + 1) < configuration.timingFrequency {
            // Neighbouring notes' partials lie further apart up high, so the attack shows sharply there.
            let ups = (0..<Self.partialCount).filter {
                f0 * Double($0 + 1) >= configuration.timingFrequency && k + Self.partialStep[$0] < bandCount
                    && ev.gain[k + Self.partialStep[$0]] > 0
            }
            func strength(_ h: Int) -> Double { ev.gain[k + Self.partialStep[h]] * Self.partialWeight[h] }
            if let best = ups.max(by: { strength($0) < strength($1) }) { main = best }
        }
        let b = k + Self.partialStep[main]
        let hopSeconds = Double(configuration.hopSize) / configuration.sampleRate
        let firstRow = ev.level.indices.first { ev.level[$0][b] >= ev.base[b] + 6 } ?? 0
        let coarse = Double(f - (ev.level.count - 1) + firstRow + 1) * hopSeconds
        let offsets = ev.level.indices.filter { ev.present[$0][b] }.map { Double(ev.offset[$0][b]) }
        let correction = offsets.isEmpty ? 0 : Self.median(offsets) - Self.partialOffset[main]
        let frequency = 440 * pow(2, (Double(k + Pitch.lowestPianoMIDI - 69) * 100 + tuningCents
                                      + Self.partialCents[main] + correction) / 1200)
        let from = max(now - 0.4, (keyOnset[k] ?? -1) + 0.06)
        return envelopeOnset(frequency: frequency, from: from, to: now) ?? coarse
    }

    /// Demodulates the recent audio at `frequency` and finds the most recent attack: the envelope's peak in
    /// the last 0.25 s, walked back to where it was below a quarter of its rise.
    private func envelopeOnset(frequency: Double, from: Double, to: Double) -> Double? {
        let sr = configuration.sampleRate
        let newest = totalSamples                       // absolute index one past the newest sample
        let oldest = max(0, newest - Int64(ring.count - configuration.hopSize))
        let startIndex = max(oldest, Int64((from * sr).rounded(.down)))
        let endIndex = min(newest, Int64((to * sr).rounded(.down)))
        let count = Int(endIndex - startIndex)
        guard count >= 64 else { return nil }

        var envelope = [Float](repeating: 0, count: count)
        let a = exp(-1 / (0.003 * sr))
        let step = -2 * Double.pi * frequency / sr
        let rotation = (cos(step), sin(step))
        var phasor = (re: 1.0, im: 0.0)
        var y1 = (re: 0.0, im: 0.0), y2 = (re: 0.0, im: 0.0)
        var j = ringWrite - Int(newest - startIndex)
        while j < 0 { j += ring.count }
        ring.withUnsafeBufferPointer { r in
            for i in 0..<count {
                let x = Double(r[j])
                j += 1
                if j == r.count { j = 0 }
                let zr = x * phasor.re, zi = x * phasor.im
                y1 = ((1 - a) * zr + a * y1.re, (1 - a) * zi + a * y1.im)
                y2 = ((1 - a) * y1.re + a * y2.re, (1 - a) * y1.im + a * y2.im)
                envelope[i] = Float((y2.re * y2.re + y2.im * y2.im).squareRoot())
                phasor = (phasor.re * rotation.0 - phasor.im * rotation.1, phasor.re * rotation.1 + phasor.im * rotation.0)
                if i & 1023 == 1023 {
                    let norm = (phasor.re * phasor.re + phasor.im * phasor.im).squareRoot()
                    phasor = (phasor.re / norm, phasor.im / norm)
                }
            }
        }
        let recent = max(0, count - Int(0.25 * sr))
        var kPeak = recent
        for i in recent..<count where envelope[i] > envelope[kPeak] { kPeak = i }
        let kLow = max(0, kPeak - Int(0.15 * sr))
        var pre = envelope[kPeak]
        for i in kLow...kPeak { pre = min(pre, envelope[i]) }
        let threshold = pre + 0.25 * (envelope[kPeak] - pre)
        var k = kPeak
        while k > 0 && envelope[k - 1] >= threshold { k -= 1 }
        return Double(startIndex + Int64(k)) / sr - 0.004   // less the smoothing's delay
    }
}
