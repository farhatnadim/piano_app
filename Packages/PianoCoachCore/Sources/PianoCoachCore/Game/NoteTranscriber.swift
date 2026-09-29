import Foundation

/// Guesses which piano keys produced a sound, from its per-key energies (`FeatureVector.semitones`).
///
/// Repeatedly takes the strongest remaining key, checks whether it is really the octave above a
/// weaker fundamental (common for low notes through small microphones and speakers), and removes
/// the chosen note's harmonics before looking for the next one. Good for melodies and simple
/// two-hand pieces; dense chords and octaves will sometimes be missed.
public enum NoteTranscriber {
    /// Harmonics 2...10 as (semitone offset above the fundamental, expected relative strength).
    /// Strengths follow the square-root compression of `SemitoneMapper`, with some headroom.
    static let harmonics: [(offset: Int, strength: Float)] = (2...10).map { h in
        (Int((12 * log2(Double(h))).rounded()), Float(1.3 * pow(Double(h), -0.55)))
    }

    /// The most likely notes (MIDI numbers), strongest first.
    /// - Parameters:
    ///   - maxNotes: at most this many notes.
    ///   - relativeThreshold: a note must reach this fraction of the strongest key's energy.
    public static func pitches(in features: FeatureVector, maxNotes: Int = 4, relativeThreshold: Float = 0.42) -> [Int] {
        let energy = features.semitones
        guard energy.count == Pitch.pianoKeyCount, let strongest = energy.max(), strongest > 0 else { return [] }
        var residual = energy
        var found: [Int] = []
        let floor = strongest * relativeThreshold
        while found.count < maxNotes {
            guard let k = residual.indices.max(by: { residual[$0] < residual[$1] }), residual[k] >= floor else { break }
            var root = k
            // An octave-lower fundamental with its own third harmonic present is the more likely note.
            let below = k - 12
            if below >= 0, residual[below] >= 0.3 * energy[k], below + 19 < energy.count,
               energy[below + 19] >= 0.15 * energy[k], !found.contains(below + Pitch.lowestPianoMIDI) {
                root = below
            }
            let midi = root + Pitch.lowestPianoMIDI
            if !found.contains(midi) { found.append(midi) }
            // Remove what this note explains: itself and the energy its harmonics would contribute.
            let level = max(energy[root], root == k ? 0 : energy[k] / 1.3)
            residual[root] = 0
            if root != k { residual[k] = max(0, residual[k] - level * harmonics[0].strength) }
            for h in harmonics where root + h.offset < residual.count && root + h.offset != k {
                residual[root + h.offset] = max(0, residual[root + h.offset] - level * h.strength)
            }
        }
        return found
    }
}
