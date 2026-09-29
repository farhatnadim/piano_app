import Foundation

/// A pitch written as a letter name (for keyboard labels and staff notation).
public struct SpelledNote: Equatable, Sendable {
    /// "C" ... "B".
    public var letter: String
    /// -1 flat, 0 natural, +1 sharp.
    public var accidental: Int
    /// Scientific octave (middle C = C4).
    public var octave: Int

    /// Position on the staff: one step per line or space, counting letters (C4 = 28, D4 = 29, ...).
    public var staffStep: Int {
        let index = ["C", "D", "E", "F", "G", "A", "B"].firstIndex(of: letter) ?? 0
        return octave * 7 + index
    }

    /// "C", "F♯", "B♭".
    public var name: String {
        letter + (accidental > 0 ? "♯" : accidental < 0 ? "♭" : "")
    }

    /// "C4", "F♯3".
    public var nameWithOctave: String { name + String(octave) }
}

/// Spells MIDI pitches with sharps or flats depending on the key signature.
public enum NoteSpelling {
    private static let sharpSpellings: [(String, Int)] = [
        ("C", 0), ("C", 1), ("D", 0), ("D", 1), ("E", 0), ("F", 0), ("F", 1), ("G", 0), ("G", 1), ("A", 0), ("A", 1), ("B", 0),
    ]
    private static let flatSpellings: [(String, Int)] = [
        ("C", 0), ("D", -1), ("D", 0), ("E", -1), ("E", 0), ("F", 0), ("G", -1), ("G", 0), ("A", -1), ("A", 0), ("B", -1), ("B", 0),
    ]

    /// Treble-clef bottom line (E4) and bass-clef top line (A3) as staff steps.
    public static let trebleBottomLine = 30
    public static let bassTopLine = 26

    /// Spells `midi`; flat keys (negative `keyFifths`) use flats, everything else sharps.
    public static func spell(_ midi: Int, keyFifths: Int = 0) -> SpelledNote {
        let pc = Pitch.pitchClass(midi)
        let (letter, accidental) = keyFifths < 0 ? flatSpellings[pc] : sharpSpellings[pc]
        // B♯/C♭ never occur with these tables, so the octave follows MIDI's.
        let octave = Int((Double(midi) / 12).rounded(.down)) - 1
        return SpelledNote(letter: letter, accidental: accidental, octave: octave)
    }

    /// True for the black keys of a piano.
    public static func isBlackKey(_ midi: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(Pitch.pitchClass(midi))
    }
}
