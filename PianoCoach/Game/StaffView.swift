import CoreText
import PianoCoachCore
import SwiftUI

/// The "Notes" view: a grand staff that scrolls from right to left past a playhead, to learn reading
/// notes. Right-hand notes sit on the treble staff and left-hand notes on the bass staff; notes turn
/// green when they are played.
struct StaffView: View {
    let game: GameController
    let chart: NoteChart

    var body: some View {
        // Read everything the drawing needs here, so the view redraws whenever the game moves.
        let scene = StaffScene(chart: chart, position: game.position, speed: game.speed, statuses: game.statuses,
                               hitTimes: game.hitTimes, now: game.frameTime, showLetters: game.showLetters)
        Canvas { context, size in
            scene.draw(in: &context, size: size)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Music staff")
    }
}

/// Where the grand staff sits in a view of a given size.
struct StaffGeometry {
    /// Distance between two staff lines.
    let spacing: CGFloat
    /// y of the treble staff's top line (F5) and the bass staff's top line (A3).
    let trebleTop: CGFloat
    let bassTop: CGFloat
    let left: CGFloat
    let right: CGFloat

    init(size: CGSize) {
        // Room for the two staves, the gap between them, two ledger lines above and below, and letters.
        // Large enough to read comfortably on an iPad (up to 26 pt between lines), smaller on a phone.
        let spacing = max(6, min(26, size.height / 21, size.width / 30))
        let gap = spacing * (size.height / spacing > 24 ? 4.5 : 3.5)
        let systemHeight = 8 * spacing + gap
        self.spacing = spacing
        trebleTop = max(3 * spacing, (size.height - systemHeight) / 2 - spacing * 0.5)
        bassTop = trebleTop + 4 * spacing + gap
        left = 10
        right = size.width - 10
    }

    var trebleBottom: CGFloat { trebleTop + 4 * spacing }
    var bassBottom: CGFloat { bassTop + 4 * spacing }

    /// y of a staff step (see `SpelledNote.staffStep`) on the treble or bass staff.
    func y(step: Int, treble: Bool) -> CGFloat {
        treble ? trebleBottom - CGFloat(step - NoteSpelling.trebleBottomLine) * spacing / 2
               : bassTop - CGFloat(step - NoteSpelling.bassTopLine) * spacing / 2
    }

    /// Steps that need a ledger line for a note at `step` (lines are on even steps: E4 = 30 is a line).
    static func ledgerSteps(for step: Int, treble: Bool) -> [Int] {
        let (bottomLine, topLine) = treble ? (NoteSpelling.trebleBottomLine, NoteSpelling.trebleBottomLine + 8)
                                           : (NoteSpelling.bassTopLine - 8, NoteSpelling.bassTopLine)
        if step <= bottomLine - 2 {
            return Array(stride(from: bottomLine - 2, through: step, by: -2))
        }
        if step >= topLine + 2 {
            return Array(stride(from: topLine + 2, through: step, by: 2))
        }
        return []
    }
}

/// One frame of the scrolling staff.
struct StaffScene {
    let chart: NoteChart
    let position: Double
    let speed: Double
    let statuses: [NoteStatus]
    let hitTimes: [Int: Double]
    let now: Double
    let showLetters: Bool

    /// Seconds of music between the playhead and the right edge.
    static let visibleSeconds = 4.0

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 40, size.height > 40 else { return }
        context.clip(to: Path(CGRect(origin: .zero, size: size)))
        let staff = StaffGeometry(size: size)
        let s = staff.spacing
        let clefRight = staff.left + s * 4.6
        let playheadX = max(clefRight + s * 3, size.width * 0.25)
        let pixelsPerBeat = (staff.right - playheadX) / CGFloat(Self.visibleSeconds / chart.secondsPerBeat(atSpeed: speed))
        func x(_ beat: Double) -> CGFloat { playheadX + CGFloat(beat - position) * pixelsPerBeat }

        // Playhead glow, behind everything.
        let glowWidth = s * 3
        context.fill(Path(CGRect(x: playheadX - glowWidth / 2, y: staff.trebleTop - 2 * s, width: glowWidth,
                                 height: staff.bassBottom - staff.trebleTop + 4 * s)),
                     with: .linearGradient(Gradient(colors: [Color.accentColor.opacity(0), Color.accentColor.opacity(0.16),
                                                             Color.accentColor.opacity(0)]),
                                           startPoint: CGPoint(x: playheadX - glowWidth / 2, y: 0),
                                           endPoint: CGPoint(x: playheadX + glowWidth / 2, y: 0)))

        // Staff lines, the brace line and the clefs.
        let ink = Color.primary.opacity(0.75)
        for i in 0..<5 {
            for top in [staff.trebleTop, staff.bassTop] {
                let lineY = top + CGFloat(i) * s
                context.fill(Path(CGRect(x: staff.left, y: lineY - 0.5, width: staff.right - staff.left, height: 1)),
                             with: .color(ink))
            }
        }
        context.fill(Path(CGRect(x: staff.left, y: staff.trebleTop, width: 2, height: staff.bassBottom - staff.trebleTop)),
                     with: .color(ink))
        drawClefs(in: &context, staff: staff)

        // Bar lines.
        let barInk = Color.primary.opacity(0.35)
        for beat in chart.barLines {
            let barX = x(beat)
            guard barX > clefRight, barX < size.width else { continue }
            context.fill(Path(CGRect(x: barX - 0.5, y: staff.trebleTop, width: 1, height: staff.bassBottom - staff.trebleTop)),
                         with: .color(barInk))
        }

        drawNotes(in: &context, staff: staff, clefRight: clefRight, playheadX: playheadX,
                  pixelsPerBeat: pixelsPerBeat, width: size.width, x: x)

        // The playhead itself, on top.
        context.fill(Path(roundedRect: CGRect(x: playheadX - 1.5, y: staff.trebleTop - 1.5 * s, width: 3,
                                              height: staff.bassBottom - staff.trebleTop + 3 * s),
                          cornerRadius: 1.5),
                     with: .color(Color.accentColor.opacity(0.85)))
    }

    private func drawNotes(in context: inout GraphicsContext, staff: StaffGeometry, clefRight: CGFloat, playheadX: CGFloat,
                           pixelsPerBeat: CGFloat, width: CGFloat, x: (Double) -> CGFloat) {
        let s = staff.spacing
        let headWidth = s * 1.32
        let headHeight = s * 0.98
        // A tilted oval notehead, centred on the origin.
        let head = Path(ellipseIn: CGRect(x: -headWidth / 2, y: -headHeight / 2, width: headWidth, height: headHeight))
            .applying(CGAffineTransform(rotationAngle: -0.35))
        let ink = Color.primary.opacity(0.75)
        let upcoming = nextNoteTime
        var texts: [String: GraphicsContext.ResolvedText] = [:]
        func text(_ string: String, size: CGFloat, weight: Font.Weight) -> GraphicsContext.ResolvedText {
            let key = "\(string)|\(size)"
            if let cached = texts[key] { return cached }
            let resolved = context.resolve(Text(string).font(.system(size: size, weight: weight, design: .rounded)))
            texts[key] = resolved
            return resolved
        }

        for note in chart.notes {
            let noteX = x(note.time)
            if noteX > width + headWidth { break }
            let tailEnd = x(note.end)
            guard tailEnd > clefRight else { continue }
            let status = note.id < statuses.count ? statuses[note.id] : .pending
            let spelled = NoteSpelling.spell(note.midi, keyFifths: chart.keyFifths)
            let step = spelled.staffStep
            let treble = Self.isOnTreble(note: note, step: step)
            let noteY = staff.y(step: step, treble: treble)
            // Fade out as the note slides under the clefs.
            let fade = Double(max(0, min(1, (noteX - clefRight) / (s * 2))))

            let color: Color
            switch status {
            case .pending:
                color = upcoming.map { abs(note.time - $0) < 1e-3 } == true ? Color.accentColor : Color.primary
            case .hit: color = GameColors.hit
            case .missed: color = GameColors.wrong.opacity(0.75)
            case .notRequired: color = Color.gray.opacity(0.4)
            }

            // How long the note is held: a soft, hand-coloured band behind the head (grey would read as a staff line).
            if tailEnd - noteX > headWidth {
                let band = CGRect(x: noteX, y: noteY - s * 0.3, width: tailEnd - noteX, height: s * 0.6)
                let bandColor: Color
                switch status {
                case .pending: bandColor = note.hand == .right ? GameColors.rightHand : GameColors.leftHand
                default: bandColor = color
                }
                context.fill(Path(roundedRect: band, cornerRadius: s * 0.3),
                             with: .color(bandColor.opacity(0.16 * max(fade, 0.3))))
            }
            guard fade > 0 else { continue }

            var layer = context
            layer.opacity = fade

            // Ledger lines.
            for ledger in StaffGeometry.ledgerSteps(for: step, treble: treble) {
                let ledgerY = staff.y(step: ledger, treble: treble)
                layer.fill(Path(CGRect(x: noteX - headWidth * 0.85, y: ledgerY - 0.5, width: headWidth * 1.7, height: 1.2)),
                           with: .color(ink))
            }

            // A glow around notes that were just played.
            if case .hit = status, let hitTime = hitTimes[note.id], now - hitTime >= 0, now - hitTime < 0.7 {
                let age = now - hitTime
                let radius = s * CGFloat(1.2 + age * 2.5)
                layer.fill(Path(ellipseIn: CGRect(x: noteX - radius, y: noteY - radius, width: 2 * radius, height: 2 * radius)),
                           with: .radialGradient(Gradient(colors: [GameColors.hit.opacity(0.6 * (1 - age / 0.7)),
                                                                   GameColors.hit.opacity(0)]),
                                                 center: CGPoint(x: noteX, y: noteY), startRadius: 0, endRadius: radius))
            }

            layer.fill(head.offsetBy(dx: noteX, dy: noteY), with: .color(color))

            if spelled.accidental != 0 {
                var sign = text(spelled.accidental > 0 ? "♯" : "♭", size: s * 1.6, weight: .regular)
                sign.shading = .color(color)
                layer.draw(sign, at: CGPoint(x: noteX - headWidth * 0.62, y: noteY), anchor: .trailing)
            }
            if showLetters {
                var label = text(spelled.name, size: max(9, s * 0.95), weight: .bold)
                label.shading = .color(status == .pending ? Color.secondary : color)
                // Below the head, clear of its ledger lines.
                layer.draw(label, at: CGPoint(x: noteX, y: noteY + headHeight / 2 + s * 0.35), anchor: .top)
            }
        }
    }

    /// Start time of the next notes to play (they are shown in the accent colour).
    private var nextNoteTime: Double? {
        for note in chart.notes where note.time >= position - 0.05 {
            if note.id < statuses.count, statuses[note.id] == .pending { return note.time }
        }
        return nil
    }

    /// Right hand on the treble staff, left hand on the bass staff, unless that would need more than
    /// three ledger lines (then the pitch decides).
    static func isOnTreble(note: ChartNote, step: Int) -> Bool {
        switch note.hand {
        case .right: return step >= 24 || note.midi >= 60
        case .left: return step > 32 && note.midi >= 60
        }
    }

    private func drawClefs(in context: inout GraphicsContext, staff: StaffGeometry) {
        let s = staff.spacing
        let clefX = staff.left + s * 0.6
        let ink = Color.primary.opacity(0.85)
        if let font = ClefFont.shared {
            // Treble clef: about 7 spaces tall, reaching 1.4 spaces below the staff.
            drawGlyph(ClefFont.trebleClef, font: font, bounds: font.trebleBounds, height: 7.2 * s,
                      bottom: staff.trebleBottom + 1.4 * s, left: clefX, color: ink, in: &context)
            // Bass clef: from the top line down about three spaces, dots included.
            drawGlyph(ClefFont.bassClef, font: font, bounds: font.bassBounds, height: 3.2 * s,
                      bottom: staff.bassTop + 3.1 * s, left: clefX, color: ink, in: &context)
        } else {
            // No music font: letter clefs centred on their lines (G4 and F3).
            var g = context.resolve(Text("G").font(.system(size: s * 3.4, weight: .heavy, design: .serif)))
            g.shading = .color(ink)
            context.draw(g, at: CGPoint(x: clefX + s * 1.2, y: staff.y(step: 32, treble: true)), anchor: .center)
            var f = context.resolve(Text("F").font(.system(size: s * 3.2, weight: .heavy, design: .serif)))
            f.shading = .color(ink)
            let fY = staff.y(step: 24, treble: false)
            context.draw(f, at: CGPoint(x: clefX + s * 1.1, y: fY), anchor: .center)
            for dy in [-0.5, 0.5] {
                let dot = s * 0.36
                context.fill(Path(ellipseIn: CGRect(x: clefX + s * 2.35, y: fY + CGFloat(dy) * s - dot / 2,
                                                    width: dot, height: dot)),
                             with: .color(ink))
            }
        }
    }

    /// Draws a glyph scaled so its ink is `height` tall, with the ink's bottom-left at (`left`, `bottom`).
    private func drawGlyph(_ glyph: String, font: ClefFont, bounds: CGRect, height: CGFloat, bottom: CGFloat,
                           left: CGFloat, color: Color, in context: inout GraphicsContext) {
        guard bounds.height > 0 else { return }
        let fontSize = ClefFont.referenceSize * height / bounds.height
        let scale = fontSize / ClefFont.referenceSize
        var text = context.resolve(Text(glyph).font(font.font(size: fontSize)))
        text.shading = .color(color)
        let box = CGSize(width: 10_000, height: 10_000)
        let baseline = text.firstBaseline(in: box)
        // Ink bounds are measured upwards from the baseline; the text is drawn from its top-left corner.
        let baselineY = bottom + bounds.minY * scale
        let origin = CGPoint(x: left - bounds.minX * scale, y: baselineY - baseline)
        context.draw(text, at: origin, anchor: .topLeading)
    }
}

/// A font that has the treble and bass clef signs, found once at run time, and where their ink sits.
struct ClefFont {
    static let trebleClef = "\u{1D11E}"
    static let bassClef = "\u{1D122}"
    /// Font size the bounds below are measured at.
    static let referenceSize: CGFloat = 100

    /// PostScript name of the font, or nil to use the system font (whose fallback has the signs).
    let name: String?
    /// Ink bounds of each clef at `referenceSize`, measured up from the baseline.
    let trebleBounds: CGRect
    let bassBounds: CGRect

    /// A fixed size (not scaled by Dynamic Type), so the sign fits the staff.
    func font(size: CGFloat) -> Font {
        if let name { return .custom(name, fixedSize: size) }
        return .system(size: size)
    }

    static let shared: ClefFont? = find()

    private static func find() -> ClefFont? {
        let both = trebleClef + bassClef
        var candidates = ["AppleSymbols", "Apple Symbols", "NotoMusic-Regular", "Bravura"].map {
            CTFontCreateWithName($0 as CFString, referenceSize, nil)
        }
        // Whatever font the system would fall back to for these characters.
        let base = CTFontCreateWithName("Helvetica" as CFString, referenceSize, nil)
        candidates.append(CTFontCreateForString(base, both as CFString, CFRange(location: 0, length: both.utf16.count)))
        for font in candidates {
            guard let treble = inkBounds(of: trebleClef, in: font),
                  let bass = inkBounds(of: bassClef, in: font) else { continue }
            let postScriptName = CTFontCopyPostScriptName(font) as String
            if postScriptName == "LastResort" { continue }
            // Hidden system fonts (".SomeFont") can't be asked for by name; the system font falls back to them.
            let name: String? = postScriptName.hasPrefix(".") ? nil : postScriptName
            return ClefFont(name: name, trebleBounds: treble, bassBounds: bass)
        }
        return nil
    }

    /// The ink bounds of a single character, or nil if the font has no glyph for it.
    private static func inkBounds(of character: String, in font: CTFont) -> CGRect? {
        let units = Array(character.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count), glyphs[0] != 0 else { return nil }
        var glyph = glyphs[0]
        let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
        return bounds.height > 0 && bounds.width > 0 ? bounds : nil
    }
}
