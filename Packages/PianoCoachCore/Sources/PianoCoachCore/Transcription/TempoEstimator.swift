import Foundation

/// A steady beat fitted to a recording: beats fall at `beatTime + k * secondsPerBeat` for whole `k`.
public struct TempoEstimate: Hashable, Sendable {
    /// Quarter-note beats per minute.
    public var bpm: Double
    /// A moment (seconds into the recording) where a beat falls.
    public var beatTime: Double
    /// How well the notes line up with the beat, 0...1.
    public var confidence: Double

    public init(bpm: Double, beatTime: Double, confidence: Double) {
        self.bpm = bpm
        self.beatTime = beatTime
        self.confidence = confidence
    }

    public var secondsPerBeat: Double { 60 / bpm }
}

/// The meter of a recording on top of its beat.
public struct MeterEstimate: Hashable, Sendable {
    public var timeSignature: TimeSignature
    /// A moment (seconds into the recording, on the beat grid) where a measure starts.
    public var downbeatTime: Double

    public init(timeSignature: TimeSignature, downbeatTime: Double) {
        self.timeSignature = timeSignature
        self.downbeatTime = downbeatTime
    }
}

/// Finds one steady tempo and beat for a transcription, and the meter on top of it.
///
/// The beat is a single straight grid on purpose: converting seconds to beats with it and back is exact,
/// so a song played at 100 % sounds just like the recording even where the performer sped up or slowed
/// down. Candidate tempos are scored, in short windows so drifting tempo still counts, by how much of the
/// note weight lands on the grid times how many grid positions have a note (a grid twice as fast fits
/// every note but leaves half its beats empty; one twice as slow is full but misses half the notes).
/// The score is taken over all onsets and again over the melody's (the top notes), because the beat
/// usually moves with the tune: that keeps an accompaniment running in even eighth notes from doubling
/// the tempo. A broad preference for moderate tempos breaks ties. The winner is then fitted to the whole
/// song by least squares on the notes that fall on its beats.
public enum TempoEstimator {
    public struct Options: Sendable {
        public var minBPM = 40.0
        public var maxBPM = 200.0
        /// Centre of the preference for moderate tempos, and its width in octaves (one standard deviation).
        public var preferredBPM = 105.0
        public var preferenceWidth = 1.0
        /// Notes starting within this many seconds count as one onset.
        public var chordWindow = 0.03
        /// How far (seconds) a played note may stray from the beat and still count as on it.
        public var timingTolerance = 0.035

        public init() {}
    }

    /// One moment where notes start, with how strongly it stands out.
    struct Onset {
        var time: Double
        /// Accent from loudness and the number of notes.
        var salience: Double
        /// Accent from a low bass note (bass notes mostly land on strong beats).
        var bass: Double
        var lowest: Int
    }

    /// The tempo and beat of `notes`, or nil when there are too few separate onsets to tell.
    public static func estimate(_ notes: [TranscribedNote], options: Options = Options()) -> TempoEstimate? {
        let onsets = makeOnsets(notes, window: options.chordWindow)
        let melody = melodyOnsets(notes, window: options.chordWindow)
        guard onsets.count >= 4, let coarse = coarseSearch(onsets, melody: melody, options: options) else { return nil }
        let fitted = refine(onsets, period: coarse.period, anchor: coarse.anchor, tolerance: options.timingTolerance)
        return TempoEstimate(bpm: 60 / fitted.period, beatTime: nearestBeat(to: onsets[0].time, fitted),
                             confidence: coarse.confidence)
    }

    /// The beat of `notes` at a known tempo (for when the tempo is given rather than guessed).
    public static func beat(_ notes: [TranscribedNote], bpm: Double, options: Options = Options()) -> TempoEstimate? {
        let onsets = makeOnsets(notes, window: options.chordWindow)
        guard let first = onsets.first, bpm > 0, bpm.isFinite else { return nil }
        let period = 60 / bpm
        let fit = gridFit(onsets[...], period: period, sigma: options.timingTolerance)
        return TempoEstimate(bpm: bpm, beatTime: nearestBeat(to: first.time, (period, fit.phaseTime)),
                             confidence: fit.score)
    }

    /// 3/4 when accents clearly repeat every three beats, otherwise 4/4; and where measures start.
    ///
    /// Accents come from loudness, chords and especially low bass notes and changes of bass note, which in
    /// piano music mostly fall on the first beat of a measure. A song is slightly preferred to start on a
    /// downbeat.
    public static func meter(_ notes: [TranscribedNote], tempo: TempoEstimate,
                             options: Options = Options()) -> MeterEstimate {
        let onsets = makeOnsets(notes, window: options.chordWindow)
        let period = tempo.secondsPerBeat
        guard let first = onsets.first, period > 0 else {
            return MeterEstimate(timeSignature: .common, downbeatTime: tempo.beatTime)
        }
        let accents = beatAccents(onsets, period: period, beatTime: tempo.beatTime)
        let beats = accents.values.count >= 12 && isTriple(accents.values) ? 3 : 4

        let firstOffset = (first.time - tempo.beatTime) / period
        let firstBeat = Int(firstOffset.rounded())
        let firstIsOnBeat = abs(firstOffset - Double(firstBeat)) < 0.2
        let mean = accents.values.reduce(0, +) / Double(max(1, accents.values.count))
        var bestPhase = 0, bestScore = -Double.infinity
        for phase in 0..<beats {
            var sum = 0.0, count = 0
            for (i, value) in accents.values.enumerated() where mod(accents.firstBeat + i, beats) == phase {
                sum += value
                count += 1
            }
            var score = count > 0 ? sum / Double(count) : 0
            if firstIsOnBeat && mod(firstBeat, beats) == phase { score += 0.15 * mean }
            if score > bestScore + 1e-12 {
                bestScore = score
                bestPhase = phase
            }
        }
        return MeterEstimate(timeSignature: TimeSignature(beats: beats, beatType: 4),
                             downbeatTime: tempo.beatTime + Double(bestPhase) * period)
    }

    // MARK: - Onsets

    static func makeOnsets(_ notes: [TranscribedNote], window: Double) -> [Onset] {
        notes.onsetGroups(window: window).map { group in
            let members = group.map { notes[$0] }
            let loudness = members.reduce(0) { $0 + max(0.02, $1.amplitude) }
            let low = members.min { $0.midi < $1.midi }!
            let bassness = max(0, min(1, Double(64 - low.midi) / 24))
            return Onset(time: members.map(\.start).min()!, salience: pow(loudness, 0.7),
                         bass: max(0.02, low.amplitude) * bassness, lowest: low.midi)
        }
    }

    /// Onsets whose top note is the highest key sounding at that moment: the tune, as far as onsets tell.
    static func melodyOnsets(_ notes: [TranscribedNote], window: Double) -> [Onset] {
        var sounding: [TranscribedNote] = []
        var result: [Onset] = []
        for group in notes.onsetGroups(window: window) {
            let members = group.map { notes[$0] }
            let time = members.map(\.start).min()!
            let top = members.max { $0.midi < $1.midi }!
            sounding.removeAll { $0.end <= time + 0.1 }
            if sounding.allSatisfy({ $0.midi <= top.midi }) {
                result.append(Onset(time: time, salience: pow(max(0.02, top.amplitude), 0.7), bass: 0, lowest: top.midi))
            }
            sounding += members
        }
        return result
    }

    // MARK: - Tempo search

    /// Scores log-spaced tempos over overlapping windows and returns the best period with a beat time near
    /// the window where it fits best.
    static func coarseSearch(_ onsets: [Onset], melody: [Onset],
                             options: Options) -> (period: Double, anchor: Double, confidence: Double)? {
        var periods: [Double] = []
        var bpm = max(10, options.minBPM)
        while bpm <= options.maxBPM {
            periods.append(60 / bpm)
            bpm *= 1.0025
        }
        guard !periods.isEmpty else { return nil }

        let span = (onsets[0].time, onsets[onsets.count - 1].time)
        let windows = self.windows(onsets, span: span)
        let fits = windowedFits(windows, periods: periods, sigma: options.timingTolerance)
        let melodyFits = melody.count >= 4
            ? windowedFits(self.windows(melody, span: span), periods: periods, sigma: options.timingTolerance)
            : [Double](repeating: 1, count: periods.count)
        var best = 0, bestScore = -1.0
        for (p, period) in periods.enumerated() {
            let octaves = log2(60 / period / options.preferredBPM) / options.preferenceWidth
            let score = fits[p] * melodyFits[p] * exp(-0.5 * octaves * octaves)
            if score > bestScore {
                bestScore = score
                best = p
            }
        }
        let period = periods[best]
        let windowFits = windows.map { $0.weight * gridFit($0.onsets, period: period, sigma: options.timingTolerance).score }
        let anchorWindow = windows[windowFits.indices.max { windowFits[$0] < windowFits[$1] }!]
        let anchor = gridFit(anchorWindow.onsets, period: period, sigma: options.timingTolerance).phaseTime
        return (period, anchor, fits[best])
    }

    /// Overlapping 12-second stretches of the song (the whole song when shorter), with their accent weight.
    static func windows(_ onsets: [Onset], span: (Double, Double)) -> [(onsets: ArraySlice<Onset>, weight: Double)] {
        let length = 12.0, hop = 6.0
        var result: [(onsets: ArraySlice<Onset>, weight: Double)] = []
        var lo = 0
        var start = span.0
        repeat {
            while lo < onsets.count, onsets[lo].time < start { lo += 1 }
            var hi = lo
            while hi < onsets.count, onsets[hi].time < start + length { hi += 1 }
            if hi - lo >= 4 { result.append((onsets[lo..<hi], onsets[lo..<hi].reduce(0) { $0 + $1.salience })) }
            start += hop
        } while start + length - hop < span.1
        if result.isEmpty { result = [(onsets[...], onsets.reduce(0) { $0 + $1.salience })] }
        return result
    }

    /// Grid fit of each period, averaged over the windows by their weight.
    static func windowedFits(_ windows: [(onsets: ArraySlice<Onset>, weight: Double)], periods: [Double],
                             sigma: Double) -> [Double] {
        let total = windows.reduce(0) { $0 + $1.weight }
        var fits = [Double](repeating: 0, count: periods.count)
        guard total > 0 else { return fits }
        for window in windows {
            for (p, period) in periods.enumerated() {
                fits[p] += window.weight / total * gridFit(window.onsets, period: period, sigma: sigma).score
            }
        }
        return fits
    }

    /// How well a grid of `period` fits the onsets at its best phase: the share of accent weight near a
    /// grid line times the share of grid lines with a note near them.
    static func gridFit(_ onsets: ArraySlice<Onset>, period: Double, sigma: Double) -> (score: Double, phaseTime: Double) {
        guard let first = onsets.first, let last = onsets.last else { return (0, 0) }
        let bins = 40
        var weight = [Double](repeating: 0, count: bins)
        var count = [Double](repeating: 0, count: bins)
        var total = 0.0
        for o in onsets {
            let cycles = (o.time - first.time) / period
            let x = (cycles - cycles.rounded(.down)) * Double(bins)
            let b0 = min(bins - 1, Int(x)), f = x - Double(b0), b1 = (b0 + 1) % bins
            weight[b0] += o.salience * (1 - f)
            weight[b1] += o.salience * f
            count[b0] += 1 - f
            count[b1] += f
            total += o.salience
        }
        let sigmaBins = max(0.5, sigma / period * Double(bins))
        let reach = min(bins / 2 - 1, Int((2.5 * sigmaBins).rounded(.up)))
        let kernel = (-reach...reach).map { exp(-Double($0 * $0) / (2 * sigmaBins * sigmaBins)) }
        let gridLines = ((last.time - first.time) / period).rounded(.down) + 1
        var best = 0.0, bestBin = 0
        for b in 0..<bins {
            var w = 0.0, c = 0.0
            for (k, g) in kernel.enumerated() {
                let i = mod(b + k - reach, bins)
                w += g * weight[i]
                c += g * count[i]
            }
            let score = (total > 0 ? w / total : 0) * min(1, c / gridLines)
            if score > best {
                best = score
                bestBin = b
            }
        }
        return (best, first.time + Double(bestBin) / Double(bins) * period)
    }

    /// Weighted least-squares fit of `time = anchor + k * period` to the onsets on the beat, starting around
    /// the anchor and widening until it spans the song, so a small period error cannot pile up into a
    /// wrong beat far away.
    static func refine(_ onsets: [Onset], period: Double, anchor: Double,
                       tolerance: Double) -> (period: Double, anchor: Double) {
        var fit = (period: period, anchor: anchor)
        let first = onsets[0].time, last = onsets[onsets.count - 1].time
        var horizon = max(8, 8 * period)
        var fullPasses = 0
        while fullPasses < 3 {
            let covers = anchor - horizon <= first && anchor + horizon >= last
            var sw = 0.0, sk = 0.0, st = 0.0, skk = 0.0, skt = 0.0
            var beats = Set<Int>()
            for o in onsets where abs(o.time - anchor) <= horizon {
                let k = ((o.time - fit.anchor) / fit.period).rounded()
                let d = o.time - (fit.anchor + k * fit.period)
                guard abs(d) < 0.2 * fit.period else { continue }
                let w = o.salience * exp(-d * d / (2 * 1.5 * tolerance * 1.5 * tolerance))
                sw += w; sk += w * k; st += w * o.time; skk += w * k * k; skt += w * k * o.time
                beats.insert(Int(k))
            }
            let det = sw * skk - sk * sk
            if beats.count >= 3, det > 1e-12 {
                let p = (sw * skt - sk * st) / det
                if abs(p / period - 1) < 0.04 {
                    fit = (p, (st - p * sk) / sw)
                }
            }
            if covers { fullPasses += 1 } else { horizon *= 1.6 }
        }
        return fit
    }

    static func nearestBeat(to time: Double, _ fit: (period: Double, anchor: Double)) -> Double {
        fit.anchor + ((time - fit.anchor) / fit.period).rounded() * fit.period
    }

    // MARK: - Meter

    /// Accent on each beat of the grid, from the first to the last onset.
    static func beatAccents(_ onsets: [Onset], period: Double, beatTime: Double) -> (firstBeat: Int, values: [Double]) {
        guard let first = onsets.first, let last = onsets.last else { return (0, []) }
        let firstBeat = Int(((first.time - beatTime) / period).rounded())
        let lastBeat = Int(((last.time - beatTime) / period).rounded())
        var values = [Double](repeating: 0, count: max(1, lastBeat - firstBeat + 1))
        let sigma = min(0.06, 0.12 * period)
        var previousBass: Int?
        for o in onsets {
            let x = (o.time - beatTime) / period
            let k = Int(x.rounded())
            let d = (x - x.rounded()) * period
            var accent = o.salience + 2 * o.bass
            if o.bass > 0.05 {
                if let previous = previousBass, previous != o.lowest { accent += o.bass }
                previousBass = o.lowest
            }
            let i = k - firstBeat
            if values.indices.contains(i) { values[i] += accent * exp(-d * d / (2 * sigma * sigma)) }
        }
        return (firstBeat, values)
    }

    /// True when the accents repeat every three beats clearly more than every two or four.
    static func isTriple(_ values: [Double]) -> Bool {
        let n = values.count
        let mean = values.reduce(0, +) / Double(n)
        let centred = values.map { $0 - mean }
        let energy = centred.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-12 else { return false }
        func r(_ lag: Int) -> Double {
            guard lag < n else { return 0 }
            var s = 0.0
            for k in 0..<(n - lag) { s += centred[k] * centred[k + lag] }
            return s / energy * Double(n) / Double(n - lag)
        }
        let triple = (r(3) + r(6)) / 2
        let duple = max(r(2), (r(4) + r(8)) / 2)
        return triple > duple + 0.1
    }

    private static func mod(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }
}
