import CoreText
import SwiftUI

/// The Bravura music font (SMuFL; Steinberg, SIL Open Font License, see Fonts/Bravura-OFL.txt), loaded
/// from the app bundle. Its glyphs come as paths measured in staff spaces: at 4 pt, one em is the four
/// spaces of a staff, and each glyph's origin sits where SMuFL says (a notehead's on its line or space).
final class MusicFont: @unchecked Sendable {
    static let shared = MusicFont()

    /// SMuFL code points used by the app.
    enum Glyph: UInt16 {
        case noteheadWhole = 0xE0A2, noteheadHalf = 0xE0A3, noteheadBlack = 0xE0A4
        case gClef = 0xE050, fClef = 0xE062
        case restWhole = 0xE4E3, restHalf = 0xE4E4, restQuarter = 0xE4E5, rest8th = 0xE4E6, rest16th = 0xE4E7
        case flag8thUp = 0xE240, flag8thDown = 0xE241, flag16thUp = 0xE242, flag16thDown = 0xE243
        case accidentalFlat = 0xE260, accidentalNatural = 0xE261, accidentalSharp = 0xE262
        case augmentationDot = 0xE1E7
        case metNoteWhole = 0xECA2, metNoteHalfUp = 0xECA3, metNoteQuarterUp = 0xECA5, metNote8thUp = 0xECA7,
             metNote16thUp = 0xECA9, metAugmentationDot = 0xECB7
    }

    struct Shape {
        let path: CGPath
        /// Ink bounds in staff spaces, y up from the origin.
        let bounds: CGRect
    }

    private let font: CTFont?
    private let lock = NSLock()
    private var cache: [UInt16: Shape] = [:]

    private init() {
        if let url = Bundle.main.url(forResource: "Bravura", withExtension: "otf"),
           let data = try? Data(contentsOf: url),
           let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) {
            font = CTFontCreateWithFontDescriptor(descriptor, 4, nil)
        } else {
            font = nil
        }
    }

    var isAvailable: Bool { font != nil }

    func shape(_ glyph: Glyph) -> Shape? { shape(code: glyph.rawValue) }

    /// Time-signature digit 0...9.
    func timeSignatureDigit(_ digit: Int) -> Shape? { shape(code: 0xE080 + UInt16(max(0, min(9, digit)))) }

    func shape(code: UInt16) -> Shape? {
        lock.withLock {
            if let cached = cache[code] { return cached }
            guard let font else { return nil }
            var character = code
            var glyph: CGGlyph = 0
            guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0,
                  let path = CTFontCreatePathForGlyph(font, glyph, nil) else { return nil }
            let shape = Shape(path: path, bounds: path.boundingBoxOfPath)
            cache[code] = shape
            return shape
        }
    }

    /// `shape` placed with its origin at `origin` (y down), `space` points to a staff space.
    static func path(_ shape: Shape, origin: CGPoint, space: CGFloat) -> Path {
        Path(shape.path).applying(CGAffineTransform(a: space, b: 0, c: 0, d: -space, tx: origin.x, ty: origin.y))
    }
}
