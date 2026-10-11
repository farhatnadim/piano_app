import PianoCoachCore
import SwiftUI

/// The staff turned upright so the notes rain down onto the keyboard: each line and space stands over its
/// own white key (the treble lines over E4 G4 B4 D5 F5, the bass lines over G2 B2 D3 F3 A3), time runs
/// down the screen like the falling bars, and a note head reaches the line when it should be played. Sharps
/// and flats sit in their letter's column with the sign beside them. Drawn through the same keyboard window
/// (`layout`) as the keys below, so it pans and zooms with them. Behind it, the bass and treble sides are
/// tinted and carry their clefs; the chord after the one to play has a steady blue ring (get ready).
struct RainingStaffView: View {
    let game: GameController
    let chart: NoteChart
    let layout: KeyboardLayout

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Read everything the drawing needs here, so the view redraws whenever the game moves.
        let scene = RainingStaffScene(
            chart: chart, layout: layout, position: game.position, speed: game.startSpeed, statuses: game.statuses,
            hitTimes: game.hitTimes, now: game.frameTime, upcomingKeys: game.upcomingKeys,
            catchUpOrder: game.catchUpOrder,
            isWaiting: game.isWaiting && game.phase == .playing,
            showLetters: game.showLetters, isDark: colorScheme == .dark)
        Canvas { context, size in
            scene.draw(in: &context, size: size)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Falling sheet music")
    }
}

/// One frame of the upright staff.
struct RainingStaffScene {
    let chart: NoteChart
    let layout: KeyboardLayout
    let position: Double
    /// The speed the notes are spaced for (the game's starting speed, as in `FallingNotesScene`).
    let speed: Double
    let statuses: [NoteStatus]
    let hitTimes: [Int: Double]
    let now: Double
    let upcomingKeys: [Int: Double]
    /// While the player is behind: the order to play the notes in, by note id.
    let catchUpOrder: [Int: Int]
    let isWaiting: Bool
    let showLetters: Bool
    let isDark: Bool

    /// Staff steps (see `SpelledNote.staffStep`) of the five lines of each staff, and of middle C.
    static let trebleLines = [30, 32, 34, 36, 38]
    static let bassLines = [18, 20, 22, 24, 26]
    static let middleC = 28

    /// The white key a staff step stands over (C4 = 28 → 60).
    static func whiteKey(forStep step: Int) -> Int {
        let octave = Int((Double(step) / 7).rounded(.down))
        let index = step - octave * 7
        return (octave + 1) * 12 + [0, 2, 4, 5, 7, 9, 11][index]
    }

    private var ink: Color { isDark ? Color(white: 0.92) : Color(white: 0.12) }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        context.clip(to: Path(CGRect(origin: .zero, size: size)))
        let hitY = size.height
        let secondsPerBeat = chart.secondsPerBeat(atSpeed: speed)
        let pixelsPerBeat = FallingNotesScene.pixelsPerBeat(height: size.height, secondsPerBeat: secondsPerBeat)
        let topBeat = position + Double(hitY / pixelsPerBeat)
        func y(_ beat: Double) -> CGFloat { hitY - CGFloat(beat - position) * pixelsPerBeat }
        func x(step: Int) -> CGFloat? { layout.span(of: Self.whiteKey(forStep: step), width: size.width)?.midX }

        drawBackground(in: &context, size: size)

        // The staff lines, standing up; middle C as a faint dashed line between the staves.
        for step in Self.trebleLines + Self.bassLines {
            guard let lineX = x(step: step) else { continue }
            context.fill(Path(CGRect(x: lineX - 0.75, y: 0, width: 1.5, height: size.height)),
                         with: .color(ink.opacity(0.45)))
        }
        if let cX = x(step: Self.middleC) {
            var dashed = Path()
            dashed.move(to: CGPoint(x: cX, y: 0))
            dashed.addLine(to: CGPoint(x: cX, y: size.height))
            context.stroke(dashed, with: .color(ink.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
        }

        // Bar lines across the staves.
        let barColor = ink.opacity(isDark ? 0.3 : 0.25)
        for beat in chart.barLines where beat >= position && beat <= topBeat {
            context.fill(Path(CGRect(x: 0, y: y(beat) - 0.75, width: size.width, height: 1.5)), with: .color(barColor))
        }

        // Learn mode waits at the line: a glow over the columns of the notes to play.
        if isWaiting {
            let pulse = 0.5 + 0.5 * sin(now * 5)
            for (midi, closeness) in upcomingKeys where closeness >= 0.999 {
                let step = NoteSpelling.spell(midi, keyFifths: chart.keyFifths).staffStep
                guard let span = layout.span(of: Self.whiteKey(forStep: step), width: size.width) else { continue }
                let height = min(hitY, 160)
                context.fill(Path(CGRect(x: span.x, y: hitY - height, width: span.width, height: height)),
                             with: .linearGradient(Gradient(colors: [GameColors.hint.opacity(0),
                                                                     GameColors.hint.opacity(0.2 + 0.25 * pulse)]),
                                                   startPoint: CGPoint(x: 0, y: hitY - height),
                                                   endPoint: CGPoint(x: 0, y: hitY)))
            }
        }

        // The line where notes are played.
        context.fill(Path(CGRect(x: 0, y: size.height - 26, width: size.width, height: 26)),
                     with: .linearGradient(Gradient(colors: [Color.accentColor.opacity(0), Color.accentColor.opacity(0.3)]),
                                           startPoint: CGPoint(x: 0, y: size.height - 26),
                                           endPoint: CGPoint(x: 0, y: size.height)))
        context.fill(Path(CGRect(x: 0, y: size.height - 3, width: size.width, height: 3)),
                     with: .color(Color.accentColor.opacity(0.9)))

        drawNotes(in: &context, size: size, topBeat: topBeat, y: y)
    }

    /// Behind everything: the bass side (left of middle C) and the treble side, tinted in the colours of
    /// the hands that usually play them, each with its clef, large and faded.
    private func drawBackground(in context: inout GraphicsContext, size: CGSize) {
        let split: CGFloat
        if let c = layout.span(of: 60, width: size.width) {
            split = c.midX
        } else {
            split = (layout.visibleKeys.first ?? 0) >= 60 ? 0 : size.width
        }
        let bass = CGRect(x: 0, y: 0, width: split, height: size.height)
        let treble = CGRect(x: split, y: 0, width: size.width - split, height: size.height)
        let tint = isDark ? 0.09 : 0.05
        context.fill(Path(bass), with: .color(GameColors.leftHand.opacity(tint)))
        context.fill(Path(treble), with: .color(GameColors.rightHand.opacity(tint)))
        drawClef(.fClef, overStep: 22, in: bass, size: size, in: &context)
        drawClef(.gClef, overStep: 34, in: treble, size: size, in: &context)
    }

    /// A clef as a watermark over its staff (centred on `step`'s column, kept inside `region`).
    private func drawClef(_ glyph: MusicFont.Glyph, overStep step: Int, in region: CGRect, size: CGSize,
                          in context: inout GraphicsContext) {
        guard region.width > 24, let shape = MusicFont.shared.shape(glyph), shape.bounds.height > 0 else { return }
        // About as tall as the staff (eight white keys) is wide, within the view.
        let staffWidth = layout.whiteKeyWidth(forWidth: size.width) * 8
        let height = min(region.height * 0.55, max(90, staffWidth * 1.5))
        let space = height / shape.bounds.height
        let width = shape.bounds.width * space
        var centerX = layout.span(of: Self.whiteKey(forStep: step), width: size.width)?.midX ?? region.midX
        centerX = width < region.width ? min(max(centerX, region.minX + width / 2), region.maxX - width / 2) : region.midX
        let centerY = region.height * 0.42
        let origin = CGPoint(x: centerX - space * shape.bounds.midX, y: centerY + space * shape.bounds.midY)
        context.fill(MusicFont.path(shape, origin: origin, space: space), with: .color(ink.opacity(isDark ? 0.1 : 0.07)))
    }

    private func drawNotes(in context: inout GraphicsContext, size: CGSize, topBeat: Double, y: (Double) -> CGFloat) {
        let white = layout.whiteKeyWidth(forWidth: size.width)
        // A head about a staff space across (two white keys would touch its neighbours: a little less).
        let headWidth = min(34, max(10, white * 1.3))
        let headHeight = headWidth * 0.78
        let catchUpCount = CatchUpShade.count(catchUpOrder)
        var letters: [String: GraphicsContext.ResolvedText] = [:]
        // The chord after the one to play now gets a steady blue ring: get ready, don't press yet.
        let preparingTime: Double? = catchUpOrder.isEmpty ? chart.notes.first { note in
            note.time > position + 1e-3 && note.id < statuses.count && statuses[note.id] == .pending
                && upcomingKeys[note.midi] != nil
        }?.time : nil

        for note in chart.notes {
            if note.time > topBeat + 0.5 { break }
            guard note.end >= position - 0.05 else { continue }
            let spelled = NoteSpelling.spell(note.midi, keyFifths: chart.keyFifths)
            let step = spelled.staffStep
            guard let span = layout.span(of: Self.whiteKey(forStep: step), width: size.width) else { continue }
            let status = note.id < statuses.count ? statuses[note.id] : .pending
            let center = CGPoint(x: span.midX, y: y(note.time))

            let color: Color
            switch status {
            case .pending:
                if let number = catchUpOrder[note.id] {
                    color = GameColors.hit.opacity(max(0.25, CatchUpShade.shown(CatchUpShade.level(number, of: catchUpCount), now: now)))
                } else if note.time <= position + 1e-3, (upcomingKeys[note.midi] ?? 0) >= 0.999 {
                    // Its turn: green, flashing.
                    color = GameColors.hit.opacity(max(0.25, CatchUpShade.shown(1, now: now)))
                } else {
                    color = ink
                }
            case .hit: color = GameColors.hit
            case .missed: color = GameColors.wrong.opacity(0.8)
            case .notRequired: color = Color.gray.opacity(0.45)
            }

            // How long it lasts: a thin tail up from the head to the note's end.
            let tailTop = y(note.end)
            if center.y - tailTop > headHeight {
                let tailWidth = max(3, headWidth * 0.22)
                context.fill(Path(roundedRect: CGRect(x: center.x - tailWidth / 2, y: tailTop, width: tailWidth,
                                                      height: center.y - tailTop),
                                  cornerRadius: tailWidth / 2),
                             with: .color(color.opacity(0.3)))
            }

            drawLedgerLines(in: &context, step: step, centerY: center.y, headHeight: headHeight, size: size)

            // The head: filled for short notes, open for half notes and longer, tilted like a printed one.
            let head = Path(ellipseIn: CGRect(x: -headWidth / 2, y: -headHeight / 2, width: headWidth, height: headHeight))
                .applying(CGAffineTransform(rotationAngle: -.pi / 9))
                .applying(CGAffineTransform(translationX: center.x, y: center.y))
            if note.duration >= 1.99 {
                context.fill(head, with: .color(isDark ? Color.black.opacity(0.4) : Color.white.opacity(0.8)))
                context.stroke(head, with: .color(color), lineWidth: max(2, headWidth * 0.12))
            } else {
                context.fill(head, with: .color(color))
            }
            if status == .pending, let preparingTime, abs(note.time - preparingTime) < 1e-3 {
                let ring = Path(ellipseIn: CGRect(x: -headWidth * 0.68, y: -headHeight * 0.72, width: headWidth * 1.36,
                                                  height: headHeight * 1.44))
                    .applying(CGAffineTransform(rotationAngle: -.pi / 9))
                    .applying(CGAffineTransform(translationX: center.x, y: center.y))
                context.stroke(ring, with: .color(GameColors.prepare), lineWidth: 3)
            }
            if let hit = hitTimes[note.id], now - hit >= 0, now - hit < 0.6 {
                let fade = 1 - (now - hit) / 0.6
                let r = headWidth * CGFloat(0.8 + (now - hit) * 1.5)
                context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                             with: .radialGradient(Gradient(colors: [GameColors.hit.opacity(0.7 * fade), GameColors.hit.opacity(0)]),
                                                   center: center, startRadius: 0, endRadius: r))
            }

            // Sharp or flat to the left of the head; the letter to its right.
            if spelled.accidental != 0 {
                let sign = context.resolve(Text(spelled.accidental > 0 ? "♯" : "♭")
                    .font(.system(size: headHeight * 1.25, weight: .bold)).foregroundStyle(color))
                context.draw(sign, at: CGPoint(x: center.x - headWidth * 0.62, y: center.y), anchor: .trailing)
            }
            if showLetters, status != .notRequired {
                let name = spelled.name
                if letters[name] == nil {
                    letters[name] = context.resolve(Text(name)
                        .font(.system(size: min(15, max(9, headHeight * 0.75)), weight: .bold, design: .rounded)))
                }
                if var text = letters[name] {
                    text.shading = .color(color == ink ? ink.opacity(0.7) : color)
                    context.draw(text, at: CGPoint(x: center.x + headWidth * 0.62, y: center.y), anchor: .leading)
                }
            }
        }
    }

    /// Short lines (upright too) through and between the head and the staff, for notes above or below
    /// it and for middle C.
    private func drawLedgerLines(in context: inout GraphicsContext, step: Int, centerY: CGFloat, headHeight: CGFloat,
                                 size: CGSize) {
        var steps: [Int] = []
        if step >= Self.trebleLines.last! + 2 {
            steps = Array(stride(from: Self.trebleLines.last! + 2, through: step, by: 2))
        } else if step <= Self.bassLines.first! - 2 {
            steps = Array(stride(from: Self.bassLines.first! - 2, through: step, by: -2))
        } else if step == Self.middleC {
            steps = [Self.middleC]
        }
        for ledger in steps {
            guard let lineX = layout.span(of: Self.whiteKey(forStep: ledger), width: size.width)?.midX else { continue }
            let length = headHeight * 1.7
            context.fill(Path(CGRect(x: lineX - 0.75, y: centerY - length / 2, width: 1.5, height: length)),
                         with: .color(ink.opacity(0.6)))
        }
    }
}
