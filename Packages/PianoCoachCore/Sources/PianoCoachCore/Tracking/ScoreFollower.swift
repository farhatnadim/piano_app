import Foundation

/// Tuning for `ScoreFollower`.
public struct FollowerConfiguration: Sendable, Equatable {
    /// Furthest forward skip (in events) considered per onset (missed notes, notes the child leaves out).
    public var lookAhead: Int = 4
    /// Furthest backward jump (in events) considered per onset (the child goes back to fix something).
    public var lookBehind: Int = 16
    /// Prior weight: the onset is the next expected event.
    public var advanceWeight: Double = 0.62
    /// Prior weight: the same event again (a rolled chord, the other hand, a repeated attempt).
    public var reattackWeight: Double = 0.08
    /// Prior weight shared by forward skips (halving with each extra event skipped).
    public var skipWeight: Double = 0.12
    /// Prior weight shared by backward jumps (measure starts and the very beginning are favoured).
    public var backWeight: Double = 0.04
    /// Prior weight: the onset is not in the score (wrong note, noise, the video's own sound).
    public var noiseWeight: Double = 0.14
    /// Emission likelihood is `exp(sharpness * (similarity - 1))`.
    public var sharpness: Double = 7
    /// Similarity assumed for the "not in the score" explanation.
    public var noiseSimilarity: Double = 0.45
    /// Blend of chroma vs semitone similarity (see `FeatureVector.similarity`).
    public var chromaWeight: Float = 0.5
    /// Use the child's current tempo to prefer events at the expected time.
    public var useTiming: Bool = true
    /// A silence longer than this (seconds) starts a new tempo segment.
    public var pauseGap: Double = 2.0

    public init() {}

    /// Preset for tracks learned from the video's sound: denser events (accompaniment, echoes),
    /// so skipping ahead is more common.
    public static var learnedTrack: FollowerConfiguration {
        var c = FollowerConfiguration()
        c.lookAhead = 7
        c.skipWeight = 0.2
        c.advanceWeight = 0.54
        c.chromaWeight = 0.6
        return c
    }
}

/// Real-time score follower: keeps a probability distribution over "which event of the track did
/// the child play last" and updates it with every onset (a hidden-Markov-model forward step).
///
/// Transitions encode how children practise — mostly the next note, sometimes a repeated or skipped
/// note, occasionally going back to the start of a measure — and each candidate event is scored by
/// how similar the heard pitch content is to the event's expected pitch content.
public final class ScoreFollower {
    public let track: FollowTrack
    public var configuration: FollowerConfiguration

    public private(set) var state = FollowerState()
    /// Whether the most recent onset was explained by the track (false = treated as noise/wrong note).
    public private(set) var lastOnsetWasMatched = false
    /// Similarity between the most recent onset and the event it was matched to.
    public private(set) var lastMatchSimilarity: Float = 0

    /// belief[s + 1] = P(last played event is s), s in -1 ..< events.count.
    private var belief: [Double]
    private var tempo = TempoRatioEstimator()
    private var measureStart: [Bool]
    /// The event the child was expected to start with after the last reset.
    private var expectedStartIndex = 0

    public init(track: FollowTrack, configuration: FollowerConfiguration = FollowerConfiguration()) {
        self.track = track
        self.configuration = configuration
        belief = [Double](repeating: 0, count: track.events.count + 1)
        belief[0] = 1
        // Events that begin a measure (or, for learned tracks, follow a gap) are likely restart points.
        var starts = [Bool](repeating: false, count: track.events.count)
        for (i, e) in track.events.enumerated() {
            if let b = e.beatInMeasure {
                starts[i] = b < 1e-6
            } else if i == 0 || e.videoTime - track.events[i - 1].videoTime > 1.2 {
                starts[i] = true
            }
        }
        if !starts.isEmpty { starts[0] = true }
        measureStart = starts
    }

    // MARK: - Positioning

    /// Places the follower just before the first event at or after `videoTime` (the child is expected to
    /// start there). Clears "started" and tempo segment history but keeps the tempo prior.
    public func reset(toVideoTime videoTime: Double) {
        let next = track.eventIndex(atOrAfterVideoTime: videoTime - 0.15) ?? track.events.count
        reset(toEventIndex: next, videoTime: videoTime)
    }

    /// Places the follower just before event `index` (the next expected event is `index`).
    public func reset(toEventIndex index: Int) {
        let clamped = max(0, min(index, track.events.count))
        let t = clamped < track.events.count ? track.events[clamped].videoTime : track.endTime
        reset(toEventIndex: clamped, videoTime: t)
    }

    private func reset(toEventIndex next: Int, videoTime: Double) {
        for i in belief.indices { belief[i] = 0 }
        expectedStartIndex = next
        let s = next - 1                      // state "last played = next - 1"
        belief[s + 1] = 0.8
        if s - 1 >= -1 { belief[s] += 0.1 } else { belief[s + 1] += 0.1 }
        if s + 1 < track.events.count { belief[s + 2] += 0.1 } else { belief[s + 1] += 0.1 }
        tempo.restartSegment()
        state = FollowerState(eventIndex: -1, videoTime: videoTime, confidence: 0.8,
                              lastMatchClockTime: nil, tempoRatio: tempo.ratio, jumped: false)
        lastOnsetWasMatched = false
    }

    /// Forgets the child's tempo too (e.g. a different child or a new session).
    public func resetTempo() {
        tempo.reset()
        state.tempoRatio = nil
    }

    // MARK: - Update

    /// Incorporates one onset heard at `clockTime` (seconds on the caller's monotonic clock).
    @discardableResult
    public func process(_ onset: NoteOnset, at clockTime: Double) -> FollowerState {
        let n = track.events.count
        guard n > 0 else { return state }
        let c = configuration

        var emissionCache = [Int: Double]()
        var similarityCache = [Int: Float]()
        func emission(_ j: Int) -> Double {
            if let e = emissionCache[j] { return e }
            let sim = similarity(onset, track.events[j])
            similarityCache[j] = sim
            let e = exp(c.sharpness * (Double(sim) - 1))
            emissionCache[j] = e
            return e
        }
        let noiseEmission = exp(c.sharpness * (c.noiseSimilarity - 1))

        // Timing prior: where should the child be now given their tempo?
        var expectedVideo: Double?
        if c.useTiming, let ratio = tempo.ratio, state.hasStarted, let last = state.lastMatchClockTime {
            let dt = clockTime - last
            if dt < c.pauseGap { expectedVideo = state.videoTime + ratio * dt }
        }
        func timing(_ from: Int, _ j: Int) -> Double {
            guard let expected = expectedVideo, from >= 0 else { return 1 }
            let base = track.events[from].videoTime
            let sigma = max(0.25, 0.6 * abs(expected - base))
            let d = (track.events[j].videoTime - expected) / sigma
            return 0.35 + exp(-0.5 * d * d)
        }

        var next = [Double](repeating: 0, count: n + 1)
        var noiseMass = 0.0
        var matchMass = 0.0
        let skipNorm = (0..<max(0, c.lookAhead - 1)).reduce(0.0) { $0 + pow(0.5, Double($1)) }

        for si in 0...n where belief[si] > 1e-7 {
            let s = si - 1                   // last played event (-1 = none)
            let b = belief[si]

            // Not in the score: stay put.
            let noise = b * c.noiseWeight * noiseEmission
            next[si] += noise
            noiseMass += noise

            // Same event again.
            if s >= 0 {
                let v = b * c.reattackWeight * emission(s)
                next[si] += v
                matchMass += v
            }
            // Next event.
            if s + 1 < n {
                let v = b * c.advanceWeight * emission(s + 1) * timing(s, s + 1)
                next[s + 2] += v
                matchMass += v
            }
            // Skips.
            if skipNorm > 0 {
                for k in 2...max(2, c.lookAhead) where s + k < n {
                    let w = c.skipWeight * pow(0.5, Double(k - 2)) / skipNorm
                    let v = b * w * emission(s + k) * timing(s, s + k)
                    next[s + k + 1] += v
                    matchMass += v
                }
            }
            // Backward jumps (to an earlier event, which is then the one just played).
            if s >= 1 {
                let lo = max(0, s - c.lookBehind)
                var targets: [(Int, Double)] = []
                var total = 0.0
                for j in lo..<s {
                    let w = measureStart[j] ? 3.0 : 1.0
                    targets.append((j, w))
                    total += w
                }
                if lo > 0 {
                    targets.append((0, 3))
                    total += 3
                }
                for (j, w) in targets {
                    let v = b * c.backWeight * (w / total) * emission(j)
                    next[j + 1] += v
                    matchMass += v
                }
            }
        }

        let total = noiseMass + matchMass
        guard total > 1e-300 else { return state }
        for i in next.indices { next[i] /= total }
        // Keep a small floor around the previous best guess so the follower can always recover.
        belief = next

        var best = 0
        for i in belief.indices where belief[i] > belief[best] { best = i }
        let bestEvent = best - 1
        let confidence = (max(0, best - 1)...min(n, best + 1)).reduce(0) { $0 + belief[$1] }
        let matched = matchMass / total > 0.5 && bestEvent >= 0
        lastOnsetWasMatched = matched
        lastMatchSimilarity = bestEvent >= 0 ? (similarityCache[bestEvent] ?? similarity(onset, track.events[bestEvent])) : 0

        var newState = state
        newState.confidence = confidence
        newState.jumped = false
        if matched {
            let previous = state.eventIndex
            let wasStarted = state.hasStarted
            if let lastClock = state.lastMatchClockTime, clockTime - lastClock > c.pauseGap {
                tempo.restartSegment()
            }
            if bestEvent != previous || !wasStarted {
                let sequential = wasStarted
                    ? (bestEvent == previous + 1 || bestEvent == previous + 2)
                    : abs(bestEvent - expectedStartIndex) <= 2
                if !sequential {
                    newState.jumped = true
                    tempo.restartSegment()
                }
                newState.eventIndex = bestEvent
                newState.videoTime = track.events[bestEvent].videoTime
                newState.tempoRatio = tempo.add(clockTime: clockTime, videoTime: newState.videoTime)
            }
            newState.lastMatchClockTime = clockTime
        }
        state = newState
        return state
    }

    // MARK: - Queries

    /// Where the child is expected to be at `clockTime`, in video seconds: the last matched event
    /// advanced at the child's tempo, but never past the next event they have not played yet.
    public func estimatedVideoTime(at clockTime: Double) -> Double {
        guard state.hasStarted, let lastClock = state.lastMatchClockTime else { return state.videoTime }
        let i = state.eventIndex
        let current = track.events[i].videoTime
        guard let ratio = tempo.ratio else { return current }
        let cap = i + 1 < track.events.count ? track.events[i + 1].videoTime - 0.02 : current + 2
        return max(current, min(cap, current + ratio * max(0, clockTime - lastClock)))
    }

    /// Seconds (at the child's pace) between the last matched event and the next one — how long a
    /// silence is expected right now. Nil before the child starts.
    public func expectedGapSeconds() -> Double? {
        guard state.hasStarted else { return nil }
        let i = state.eventIndex
        guard i + 1 < track.events.count else { return nil }
        let gap = track.events[i + 1].videoTime - track.events[i].videoTime
        let ratio = max(0.15, tempo.ratio ?? 1)
        return min(8, gap / ratio)
    }

    /// The next event the child is expected to play.
    public var nextExpectedEvent: TrackEvent? {
        let i = state.hasStarted ? state.eventIndex + 1 : (belief.indices.max { belief[$0] < belief[$1] } ?? 0)
        return track.events.indices.contains(i) ? track.events[i] : nil
    }

    /// The last event the child played, if any.
    public var currentEvent: TrackEvent? {
        state.hasStarted ? track.events[state.eventIndex] : nil
    }

    // MARK: - Similarity

    private func similarity(_ onset: NoteOnset, _ event: TrackEvent) -> Float {
        if let played = onset.midiPitches, !event.pitches.isEmpty {
            // Exact notes from a MIDI keyboard: compare pitch sets directly (F-measure), blended with
            // features so octave slips still count for something.
            let expected = Set(event.pitches), got = Set(played)
            let hits = Float(expected.intersection(got).count)
            let precision = got.isEmpty ? 0 : hits / Float(got.count)
            let recall = hits / Float(expected.count)
            let f = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
            let feat = onset.features.similarity(to: event.features, chromaWeight: configuration.chromaWeight)
            return max(f, 0.8 * feat)
        }
        return onset.features.similarity(to: event.features, chromaWeight: configuration.chromaWeight)
    }
}
