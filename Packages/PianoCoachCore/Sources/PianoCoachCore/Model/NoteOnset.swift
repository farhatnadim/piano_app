import Foundation

/// A detected "something was just played" moment: a single note or a chord.
///
/// Produced by `OnsetAnalyzer` (microphone) or `MIDINoteGrouper` (MIDI keyboard) and consumed by
/// `ScoreFollower`, `TrackRecorder` and `PacingController`.
public struct NoteOnset: Codable, Hashable, Sendable {
    /// Time of the attack in seconds on the producer's clock. For the analyser this is
    /// "seconds of audio consumed since reset"; callers convert it to their own clock.
    public var time: Double
    /// Onset strength (peak of the onset detection function, roughly 0...1+). Higher = louder/clearer attack.
    public var strength: Float
    /// RMS level around the onset in dBFS (e.g. -30). MIDI onsets map velocity to a comparable range.
    public var levelDB: Float
    /// Pitch content shortly after the attack.
    public var features: FeatureVector
    /// Exact MIDI pitches when known (MIDI keyboard input); nil for microphone input.
    public var midiPitches: [Int]?

    public init(time: Double, strength: Float, levelDB: Float, features: FeatureVector, midiPitches: [Int]? = nil) {
        self.time = time
        self.strength = strength
        self.levelDB = levelDB
        self.features = features
        self.midiPitches = midiPitches
    }
}
