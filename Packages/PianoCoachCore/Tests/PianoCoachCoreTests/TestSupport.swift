import Foundation
@testable import PianoCoachCore

/// Deterministic helpers shared by the tracking and pacing tests.
enum TestSupport {
    /// "Ode to Joy"-like melody with a left-hand note on each downbeat, 4/4, 8 measures of quarter notes.
    static func melodyScore() -> Score {
        let melody = [64, 64, 65, 67, 67, 65, 64, 62, 60, 60, 62, 64, 64, 62, 62, 60,
                      64, 64, 65, 67, 67, 65, 64, 62, 60, 60, 62, 64, 62, 60, 60, 60]
        let bass = [48, 43, 45, 43, 48, 43, 45, 43]
        var events: [ScoreEvent] = []
        var measures: [ScoreMeasure] = []
        for m in 0..<8 {
            measures.append(ScoreMeasure(index: m, sourceIndex: m, number: "\(m + 1)", startBeat: Double(m * 4),
                                         lengthBeats: 4, timeSignature: .common))
        }
        for (i, p) in melody.enumerated() {
            let beat = Double(i)
            let m = i / 4
            var pitches = [p]
            if i % 4 == 0 { pitches.insert(bass[m], at: 0) }
            events.append(ScoreEvent(index: i, beat: beat, measureIndex: m, sourceMeasureIndex: m,
                                     beatInMeasure: beat - Double(m * 4), pitches: pitches, durationBeats: 1))
        }
        return Score(title: "Test", measures: measures, events: events, initialTempoBPM: 100)
    }

    /// Feature vector for the given pitches with deterministic perturbation (to mimic a microphone).
    static func noisyFeatures(_ pitches: [Int], noise: Float, seed: Int) -> FeatureVector {
        var raw = FeatureVector.template(forPitches: pitches).semitones
        var state = UInt64(seed &* 2654435761 &+ 1)
        for k in raw.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let r = Float(state >> 40) / Float(1 << 24)
            raw[k] = max(0, raw[k] + noise * r * r * 0.6)
        }
        return FeatureVector(semitones: raw)
    }

    static func onset(_ pitches: [Int], at time: Double, noise: Float = 0.3, seed: Int = 0) -> NoteOnset {
        NoteOnset(time: time, strength: 1, levelDB: -30, features: noisyFeatures(pitches, noise: noise, seed: seed))
    }
}
