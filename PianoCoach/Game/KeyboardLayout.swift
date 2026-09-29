import Foundation
import PianoCoachCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where the keys of a real 88-key piano (A0 to C8) are drawn, and which part of the keyboard is in view.
///
/// Places on the piano are measured in white keys from A0's left edge, so C8's right edge is at 52. The view
/// shows a window of the keyboard `visibleWhiteKeys` wide, starting at `visibleStart`. Both may be fractional,
/// so the window can pan and zoom smoothly; keys cut by its edges are drawn in part. The falling notes, the
/// keyboard and the minimap share one layout, so every note falls exactly onto its key.
struct KeyboardLayout: Equatable {
    static let lowestKey = Pitch.lowestPianoMIDI
    static let highestKey = Pitch.highestPianoMIDI
    static let whiteKeyTotal = 52

    /// Black keys cover this fraction of the keyboard's height.
    static let blackKeyDepth: CGFloat = 0.62
    /// Width of a black key relative to a white key.
    static let blackKeyWidth: CGFloat = 0.58

    /// Left edge of the window, in white keys from A0's left edge.
    let visibleStart: Double
    /// Width of the window, in white keys.
    let visibleWhiteKeys: Double

    static let wholeKeyboard = KeyboardLayout(visibleStart: 0, visibleWhiteKeys: Double(whiteKeyTotal))

    /// A window `visibleWhiteKeys` wide (one key to all 52) from `visibleStart`, kept on the piano.
    init(visibleStart: Double, visibleWhiteKeys: Double) {
        let total = Double(Self.whiteKeyTotal)
        let width = visibleWhiteKeys.isFinite ? min(total, max(1, visibleWhiteKeys)) : total
        self.visibleWhiteKeys = width
        self.visibleStart = visibleStart.isFinite ? min(total - width, max(0, visibleStart)) : 0
    }

    /// Exactly the keys from `lowest` to `highest` (kept on the piano).
    init(lowest: Int, highest: Int) {
        let low = Self.extent(of: max(Self.lowestKey, min(lowest, highest)))
        let high = Self.extent(of: min(Self.highestKey, max(lowest, highest)))
        self.init(visibleStart: low.lowerBound, visibleWhiteKeys: high.upperBound - low.lowerBound)
    }

    var visibleEnd: Double { visibleStart + visibleWhiteKeys }

    var showsWholeKeyboard: Bool { visibleWhiteKeys >= Double(Self.whiteKeyTotal) - 1e-6 }

    /// The keys at least partly in view, lowest to highest.
    var visibleKeys: ClosedRange<Int> {
        var low = Self.whiteKeyMIDI[min(Self.whiteKeyTotal - 1, max(0, Int(visibleStart.rounded(.down))))]
        if low > Self.lowestKey, Self.isBlackKey(low - 1), Self.extent(of: low - 1).upperBound > visibleStart {
            low -= 1
        }
        var high = Self.whiteKeyMIDI[min(Self.whiteKeyTotal - 1, max(0, Int(visibleEnd.rounded(.up)) - 1))]
        if high < Self.highestKey, Self.isBlackKey(high + 1), Self.extent(of: high + 1).lowerBound < visibleEnd {
            high += 1
        }
        return low...high
    }

    /// The keys in view in words, for VoiceOver: "All 88 keys", or "C3 to E5".
    var keysInView: String {
        if showsWholeKeyboard { return "All 88 keys" }
        let keys = visibleKeys
        return NoteSpelling.spell(keys.lowerBound).nameWithOctave + " to "
            + NoteSpelling.spell(keys.upperBound).nameWithOctave
    }

    /// Whether a key is at least partly in view.
    func contains(_ midi: Int) -> Bool {
        guard Self.isOnPiano(midi) else { return false }
        let extent = Self.extent(of: midi)
        return extent.upperBound > visibleStart && extent.lowerBound < visibleEnd
    }

    /// Width of one white key on a keyboard `width` points wide.
    func whiteKeyWidth(forWidth width: CGFloat) -> CGFloat {
        width / CGFloat(visibleWhiteKeys)
    }

    /// x of a place on the piano (in white keys from A0's left edge) on a keyboard `width` points wide.
    func x(atPianoPosition position: Double, width: CGFloat) -> CGFloat {
        CGFloat(position - visibleStart) * whiteKeyWidth(forWidth: width)
    }

    /// Where a key is drawn on a keyboard `width` points wide (black keys are narrower and sit between white
    /// keys, shifted a little the way a real piano's are). Keys cut by the window's edges reach past 0 or
    /// `width`. Nil for keys that are out of view or not on a piano.
    func span(of midi: Int, width: CGFloat) -> KeySpan? {
        guard contains(midi) else { return nil }
        let extent = Self.extent(of: midi)
        let left = x(atPianoPosition: extent.lowerBound, width: width)
        let right = x(atPianoPosition: extent.upperBound, width: width)
        return KeySpan(x: left, width: right - left, isBlack: Self.isBlackKey(midi))
    }

    /// The key under `point` on a keyboard of `size` (black keys win in their upper part).
    func key(at point: CGPoint, size: CGSize) -> Int? {
        guard size.width > 0, point.x >= 0, point.x < size.width, point.y >= 0, point.y <= size.height else {
            return nil
        }
        let position = visibleStart + Double(point.x / whiteKeyWidth(forWidth: size.width))
        let index = min(Self.whiteKeyTotal - 1, max(0, Int(position.rounded(.down))))
        let whiteKey = Self.whiteKeyMIDI[index]
        if point.y < size.height * Self.blackKeyDepth {
            // A black key reaches less than half a white key past the gap it sits in.
            for midi in [whiteKey - 1, whiteKey + 1] where Self.isOnPiano(midi) && Self.isBlackKey(midi) {
                let extent = Self.extent(of: midi)
                if position >= extent.lowerBound && position < extent.upperBound { return midi }
            }
        }
        return whiteKey
    }

    // MARK: - The piano

    static func isOnPiano(_ midi: Int) -> Bool { midi >= lowestKey && midi <= highestKey }

    /// True for the black keys (without allocating, unlike `NoteSpelling.isBlackKey`; this runs every frame).
    static func isBlackKey(_ midi: Int) -> Bool {
        switch Pitch.pitchClass(midi) {
        case 1, 3, 6, 8, 10: return true
        default: return false
        }
    }

    /// Left and right edges of a key, in white keys from A0's left edge (keys off the piano: the nearest end).
    static func extent(of midi: Int) -> ClosedRange<Double> {
        extents[max(lowestKey, min(highestKey, midi)) - lowestKey]
    }

    /// The white keys, A0 to C8.
    static let whiteKeyMIDI: [Int] = (lowestKey...highestKey).filter { !isBlackKey($0) }

    /// `extent(of:)` for every key, A0 to C8.
    private static let extents: [ClosedRange<Double>] = {
        var result: [ClosedRange<Double>] = []
        var whitesBefore = 0
        for midi in lowestKey...highestKey {
            if isBlackKey(midi) {
                let center = Double(whitesBefore) + blackKeyShift(midi)
                let half = Double(blackKeyWidth) / 2
                result.append((center - half)...(center + half))
            } else {
                result.append(Double(whitesBefore)...Double(whitesBefore + 1))
                whitesBefore += 1
            }
        }
        return result
    }()

    /// Offset of a black key's centre from the gap between its white neighbours, in white-key widths.
    private static func blackKeyShift(_ midi: Int) -> Double {
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
