import Foundation

/// A detected "something was just played" moment: a single note or a chord.
///
/// Produced by `PianoKeyListener` or `OnsetAnalyzer` (microphone) or `MIDINoteGrouper` (MIDI keyboard) and
/// consumed by the game, `ScoreFollower`, `TrackRecorder` and `PacingController`.
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
    /// The keys played, when known: exact for a MIDI keyboard or the screen, the keys `PianoKeyListener` heard
    /// for the microphone. nil when only `features` are known.
    public var midiPitches: [Int]?
    /// For keys heard by `PianoKeyListener`: whether it took them for a wrong note (none of the keys it was
    /// told to expect). nil for exact input (MIDI keyboard, screen).
    public var heardAsWrong: Bool?

    public init(time: Double, strength: Float, levelDB: Float, features: FeatureVector, midiPitches: [Int]? = nil,
                heardAsWrong: Bool? = nil) {
        self.time = time
        self.strength = strength
        self.levelDB = levelDB
        self.features = features
        self.midiPitches = midiPitches
        self.heardAsWrong = heardAsWrong
    }
}
