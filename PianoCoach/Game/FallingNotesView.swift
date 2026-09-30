import PianoCoachCore
import SwiftUI

/// The notes falling towards the keyboard: one bar per note in its key's lane, reaching the hit line at
/// the bottom exactly when it should be played. Drawn in a single Canvas every frame, through the same
/// window of the keyboard as the keys below (`layout`), so the lanes pan and zoom with them.
struct FallingNotesView: View {
    let game: GameController
    let chart: NoteChart
    let layout: KeyboardLayout

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Read everything the drawing needs here, so the view redraws whenever the game moves.
        let scene = FallingNotesScene(
            chart: chart, layout: layout, position: game.position, speed: game.speed, statuses: game.statuses,
            hitTimes: game.hitTimes, now: game.frameTime, upcomingKeys: game.upcomingKeys,
            isWaiting: game.isWaiting && game.phase == .playing,
            showLetters: game.showLetters, isDark: colorScheme == .dark)
        Canvas { context, size in
            scene.draw(in: &context, size: size)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Falling notes")
    }
}

/// One frame of falling notes.
struct FallingNotesScene {
    let chart: NoteChart
    let layout: KeyboardLayout
    let position: Double
    let speed: Double
    let statuses: [NoteStatus]
    let hitTimes: [Int: Double]
    let now: Double
    let upcomingKeys: [Int: Double]
    let isWaiting: Bool
    let showLetters: Bool
    let isDark: Bool

    /// Seconds of music between the top of the view and the hit line.
    static func visibleSeconds(forHeight height: CGFloat) -> Double {
        min(4, max(3, Double(height) / 170))
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        context.clip(to: Path(CGRect(origin: .zero, size: size)))
        let hitY = size.height
        let secondsPerBeat = chart.secondsPerBeat(atSpeed: speed)
        let pixelsPerBeat = hitY / CGFloat(Self.visibleSeconds(forHeight: size.height) / secondsPerBeat)
        let topBeat = position + Double(hitY / pixelsPerBeat)
        func y(_ beat: Double) -> CGFloat { hitY - CGFloat(beat - position) * pixelsPerBeat }

        drawLanes(in: &context, size: size)

        // Bar lines.
        let barColor = Color.primary.opacity(isDark ? 0.14 : 0.1)
        for beat in chart.barLines where beat >= position && beat <= topBeat {
            let lineY = y(beat)
            context.fill(Path(CGRect(x: 0, y: lineY - 0.5, width: size.width, height: 1)), with: .color(barColor))
        }

        // Learn mode waits at the line: make the keys to play glow.
        if isWaiting {
            let pulse = 0.5 + 0.5 * sin(now * 5)
            for midi in upcomingKeys.keys {
                guard let span = layout.span(of: midi, width: size.width) else { continue }
                let height = min(hitY, 160)
                context.fill(Path(CGRect(x: span.x, y: hitY - height, width: span.width, height: height)),
                             with: .linearGradient(Gradient(colors: [GameColors.hint.opacity(0),
                                                                     GameColors.hint.opacity(0.2 + 0.25 * pulse)]),
                                                   startPoint: CGPoint(x: 0, y: hitY - height),
                                                   endPoint: CGPoint(x: 0, y: hitY)))
            }
        }

        drawHitLine(in: &context, size: size)
        drawNotes(in: &context, size: size, pixelsPerBeat: pixelsPerBeat, topBeat: topBeat, y: y)
    }

    /// Faint columns behind the black keys and lines between octaves, so the lanes are easy to follow. They
    /// move with the keyboard's window.
    private func drawLanes(in context: inout GraphicsContext, size: CGSize) {
        let shade = Color.primary.opacity(isDark ? 0.06 : 0.035)
        let octaveLine = Color.primary.opacity(isDark ? 0.14 : 0.1)
        for midi in layout.visibleKeys {
            guard let span = layout.span(of: midi, width: size.width) else { continue }
            if span.isBlack {
                context.fill(Path(CGRect(x: span.x, y: 0, width: span.width, height: size.height)), with: .color(shade))
            } else if Pitch.pitchClass(midi) == 0 && span.x > 0.5 {
                context.fill(Path(CGRect(x: span.x - 0.5, y: 0, width: 1, height: size.height)), with: .color(octaveLine))
            }
        }
    }

    /// A glowing band just above the keyboard where the notes should be played.
    private func drawHitLine(in context: inout GraphicsContext, size: CGSize) {
        let band: CGFloat = 26
        context.fill(Path(CGRect(x: 0, y: size.height - band, width: size.width, height: band)),
                     with: .linearGradient(Gradient(colors: [Color.accentColor.opacity(0), Color.accentColor.opacity(0.3)]),
                                           startPoint: CGPoint(x: 0, y: size.height - band),
                                           endPoint: CGPoint(x: 0, y: size.height)))
        context.fill(Path(CGRect(x: 0, y: size.height - 3, width: size.width, height: 3)),
                     with: .color(Color.accentColor.opacity(0.9)))
    }

    private func drawNotes(in context: inout GraphicsContext, size: CGSize, pixelsPerBeat: CGFloat, topBeat: Double,
                           y: (Double) -> CGFloat) {
        let hitY = size.height
        let nearBeats = 0.35
        // Resolved once per name and frame, with its size, to label only the bars it fits in.
        var letters: [String: (text: GraphicsContext.ResolvedText, size: CGSize)] = [:]
        let dimmed = Color.gray.opacity(0.35)

        for note in chart.notes {
            if note.time > topBeat { break }
            // Keys out of the keyboard's window have no lane (the camera keeps upcoming notes in view; notes on
            // keys cut by the edges are drawn in part).
            guard note.end >= position - 0.05,
                  let lane = layout.span(of: note.midi, width: size.width) else { continue }
            let status = note.id < statuses.count ? statuses[note.id] : .pending
            let bottom = y(note.time)
            let height = max(10, CGFloat(note.duration) * pixelsPerBeat)
            let inset: CGFloat = lane.isBlack ? 1 : 2
            let rect = CGRect(x: lane.x + inset, y: bottom - height, width: lane.width - 2 * inset, height: height)
            guard rect.minY < hitY else { continue }
            let radius = min(7, rect.width * 0.3)
            let bar = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
            let handColor = GameColors.color(for: note.hand)

            switch status {
            case .pending:
                let isNear = note.time - position < nearBeats
                context.fill(bar, with: .color(handColor))
                if isNear {
                    context.fill(bar, with: .color(Color.white.opacity(0.22)))
                    context.stroke(bar, with: .color(Color.white.opacity(0.9)), lineWidth: 2)
                } else {
                    context.stroke(bar, with: .color(Color.black.opacity(0.15)), lineWidth: 1)
                }
            case .hit:
                context.fill(bar, with: .color(GameColors.hit))
                context.stroke(bar, with: .color(Color.white.opacity(0.7)), lineWidth: 1.5)
            case .missed:
                context.fill(bar, with: .color(handColor.opacity(0.22)))
                context.stroke(bar, with: .color(GameColors.wrong.opacity(0.8)), lineWidth: 1.5)
            case .notRequired:
                context.fill(bar, with: .color(dimmed))
            }

            // Letter name at the bottom of the bar, when the bar is wide enough for it (zoomed-out lanes are thin).
            if showLetters, rect.height >= 20, rect.width >= 10, status != .notRequired {
                let name = NoteSpelling.spell(note.midi, keyFifths: chart.keyFifths).name
                if letters[name] == nil {
                    let fontSize = min(15, max(9, lane.width * 0.42))
                    let font = Font.system(size: fontSize, weight: .bold, design: .rounded)
                    let text = context.resolve(Text(name).font(font))
                    letters[name] = (text, text.measure(in: CGSize(width: 200, height: 100)))
                }
                if var label = letters[name], label.size.width <= rect.width - 2, label.size.height + 4 <= rect.height {
                    label.text.shading = .color(status == .missed ? Color.primary.opacity(0.6) : .white)
                    let labelY = min(rect.maxY, hitY) - 4
                    context.draw(label.text, at: CGPoint(x: rect.midX, y: labelY), anchor: .bottom)
                }
            }
        }

        // A burst of light on the line where a note was just hit, fading out.
        for (id, hitTime) in hitTimes {
            let age = now - hitTime
            guard age >= 0, age < 0.6, id < chart.notes.count,
                  let lane = layout.span(of: chart.notes[id].midi, width: size.width) else { continue }
            let fade = 1 - age / 0.6
            let grow = CGFloat(1 + age * 1.5)
            let glowWidth = max(lane.width, 16) * 1.9 * grow
            let glowHeight = 34 * grow
            let glow = CGRect(x: lane.midX - glowWidth / 2, y: hitY - glowHeight / 2 - 2, width: glowWidth, height: glowHeight)
            context.fill(Path(ellipseIn: glow),
                         with: .radialGradient(Gradient(colors: [GameColors.hit.opacity(0.85 * fade), GameColors.hit.opacity(0)]),
                                               center: CGPoint(x: glow.midX, y: glow.midY),
                                               startRadius: 0, endRadius: glowWidth / 2))
        }
    }
}

/// "Play the glowing keys!": shown while the notes wait for the child (every chord in Learn mode; in Play
/// mode when they stopped playing).
struct WaitingHint: View {
    let game: GameController
    var text = "Play the glowing keys!"

    var body: some View {
        let show = game.isWaiting && game.phase == .playing
        ZStack {
            if show {
                Label(text, systemImage: "hand.point.down.fill")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay { Capsule().strokeBorder(GameColors.hint, lineWidth: 2) }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: show)
        .allowsHitTesting(false)
    }
}
