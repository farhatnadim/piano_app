import Foundation

/// Helpers for converting between note names, MIDI numbers and frequencies.
///
/// MIDI 60 is middle C (C4), MIDI 69 is A4 = 440 Hz. A standard 88-key piano
/// spans MIDI 21 (A0) through MIDI 108 (C8).
public enum Pitch {
    public static let lowestPianoMIDI = 21
    public static let highestPianoMIDI = 108
    public static let pianoKeyCount = 88

    private static let stepOffsets: [Character: Int] = [
        "C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11,
    ]
    private static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// MIDI number for a MusicXML-style pitch (`step` "A"..."G", `alter` in semitones, `octave` 0...9).
    /// Returns nil for an unknown step.
    public static func midiNumber(step: String, alter: Int = 0, octave: Int) -> Int? {
        guard let first = step.trimmingCharacters(in: .whitespaces).uppercased().first,
              let offset = stepOffsets[first] else { return nil }
        return (octave + 1) * 12 + offset + alter
    }

    /// Frequency in Hz of a (possibly fractional) MIDI number.
    public static func frequency(midi: Double, a4: Double = 440) -> Double {
        a4 * pow(2, (midi - 69) / 12)
    }

    /// Frequency in Hz of a MIDI number.
    public static func frequency(midi: Int, a4: Double = 440) -> Double {
        frequency(midi: Double(midi), a4: a4)
    }

    /// Fractional MIDI number for a frequency in Hz (69 = A4).
    public static func midi(forFrequency frequency: Double, a4: Double = 440) -> Double {
        guard frequency > 0 else { return -.infinity }
        return 69 + 12 * log2(frequency / a4)
    }

    /// Pitch class 0...11 (C = 0).
    public static func pitchClass(_ midi: Int) -> Int {
        ((midi % 12) + 12) % 12
    }

    /// Scientific pitch name using sharps, e.g. 60 -> "C4", 61 -> "C#4".
    public static func name(midi: Int) -> String {
        let octave = Int((Double(midi) / 12).rounded(.down)) - 1
        return "\(sharpNames[pitchClass(midi)])\(octave)"
    }

    /// Index 0...87 of a piano key (A0 = 0), or nil if outside the piano range.
    public static func pianoKeyIndex(midi: Int) -> Int? {
        guard midi >= lowestPianoMIDI, midi <= highestPianoMIDI else { return nil }
        return midi - lowestPianoMIDI
    }
}
