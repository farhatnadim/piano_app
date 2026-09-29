import PianoCoachCore
import SwiftUI

/// The piano keys a game shows and where each one is drawn.
///
/// The falling notes and the keyboard share one layout, so every note falls exactly onto its key.
struct KeyboardLayout: Equatable {
    /// Lowest and highest key shown (MIDI numbers).
    let lowest: Int
    let highest: Int
    /// The white keys shown, left to right.
    let whiteKeys: [Int]
    /// For every key from `lowest` to `highest`: how many white keys lie to its left.
    private let whiteKeysBefore: [Int]

    /// Black keys cover this fraction of the keyboard's height.
    static let blackKeyDepth: CGFloat = 0.62
    /// Width of a black key relative to a white key.
    static let blackKeyWidth: CGFloat = 0.58

    /// Keys for a chart: its notes plus two semitones each side, widened to whole octaves (C to B), at
    /// least two octaves, and never beyond a real piano (A0 to C8).
    init(chart: NoteChart?) {
        guard let chart, !chart.isEmpty else {
            self.init(lowest: 48, highest: 83)
            return
        }
        var low = chart.lowestMIDI - 2
        var high = chart.highestMIDI + 2
        low -= Pitch.pitchClass(low)
        high += 11 - Pitch.pitchClass(high)
        // Grow by whole octaves towards middle C, so it tends to stay in view.
        let middle = Double(chart.lowestMIDI + chart.highestMIDI) / 2
        while high - low + 1 < 24 {
            if middle >= 60 { low -= 12 } else { high += 12 }
        }
        low = max(Pitch.lowestPianoMIDI, low)
        high = min(Pitch.highestPianoMIDI, high)
        if high - low + 1 < 24 {
            if low == Pitch.lowestPianoMIDI {
                high = low + 23
                high = min(Pitch.highestPianoMIDI, high + 11 - Pitch.pitchClass(high))
            } else {
                low = max(Pitch.lowestPianoMIDI, high - 23)
            }
        }
        self.init(lowest: low, highest: high)
    }

    /// Keys from `lowest` to `highest`, moved outwards onto white keys if needed.
    init(lowest: Int, highest: Int) {
        var low = max(0, min(lowest, highest))
        var high = min(127, max(lowest, highest))
        if NoteSpelling.isBlackKey(low) { low -= 1 }
        if NoteSpelling.isBlackKey(high) { high += 1 }
        self.lowest = low
        self.highest = high
        var whites: [Int] = []
        var before: [Int] = []
        for midi in low...high {
            before.append(whites.count)
            if !NoteSpelling.isBlackKey(midi) { whites.append(midi) }
        }
        whiteKeys = whites
        whiteKeysBefore = before
    }

    var whiteKeyCount: Int { whiteKeys.count }

    func contains(_ midi: Int) -> Bool { midi >= lowest && midi <= highest }

    /// Width of one white key on a keyboard `width` points wide.
    func whiteKeyWidth(forWidth width: CGFloat) -> CGFloat {
        width / CGFloat(max(1, whiteKeys.count))
    }

    /// Where a key is drawn on a keyboard `width` points wide (black keys are narrower and sit between
    /// white keys, shifted a little the way a real piano's are). Nil for keys that aren't shown.
    func span(of midi: Int, width: CGFloat) -> KeySpan? {
        guard contains(midi) else { return nil }
        let white = whiteKeyWidth(forWidth: width)
        let index = CGFloat(whiteKeysBefore[midi - lowest])
        guard NoteSpelling.isBlackKey(midi) else {
            return KeySpan(x: index * white, width: white, isBlack: false)
        }
        let blackWidth = white * Self.blackKeyWidth
        let center = index * white + Self.blackKeyShift(midi) * white
        return KeySpan(x: center - blackWidth / 2, width: blackWidth, isBlack: true)
    }

    /// The key under `point` on a keyboard of `size` (black keys win in their upper part).
    func key(at point: CGPoint, size: CGSize) -> Int? {
        guard size.width > 0, point.x >= 0, point.x < size.width, point.y >= 0, point.y <= size.height else {
            return nil
        }
        let white = whiteKeyWidth(forWidth: size.width)
        let index = min(whiteKeys.count - 1, max(0, Int(point.x / white)))
        let whiteKey = whiteKeys[index]
        if point.y < size.height * Self.blackKeyDepth {
            for midi in [whiteKey - 1, whiteKey + 1] where contains(midi) && NoteSpelling.isBlackKey(midi) {
                if let span = span(of: midi, width: size.width), point.x >= span.x, point.x < span.maxX {
                    return midi
                }
            }
        }
        return whiteKey
    }

    /// Offset of a black key's centre from the gap between its white neighbours, in white-key widths.
    private static func blackKeyShift(_ midi: Int) -> CGFloat {
        switch Pitch.pitchClass(midi) {
        case 1: return -0.1   // C♯
        case 3: return 0.1    // D♯
        case 6: return -0.12  // F♯
        case 10: return 0.12  // A♯
        default: return 0     // G♯
        }
    }
}

/// The horizontal extent of one key (and of its lane of falling notes).
struct KeySpan: Equatable {
    var x: CGFloat
    var width: CGFloat
    var isBlack: Bool

    var maxX: CGFloat { x + width }
    var midX: CGFloat { x + width / 2 }
}
