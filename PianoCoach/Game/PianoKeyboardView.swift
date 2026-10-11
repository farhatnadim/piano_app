import PianoCoachCore
import SwiftUI

/// A piano keyboard drawn in one Canvas, with key glows (right, early, late, wrong), green hints on the keys
/// to play now (flashing, and only once their turn has come), a steady blue outline on the keys of the chord after
/// it (get ready, don't press yet), letter names and a mark on middle C. It shows the part of the 88 keys in `layout`'s window
/// (all of them, or the part the song is played on). Tapping or sliding across it plays keys.
struct PianoKeyboardView: View {
    let layout: KeyboardLayout
    var glows: [Int: KeyGlow] = [:]
    /// Keys to play soon: 0 = still a moment away, 1 = due now (only those show, flashing).
    var hints: [Int: Double] = [:]
    /// The clock the flashing follows (any steadily increasing seconds).
    var now: Double = 0
    var showLetters = true
    /// While catching up: how bright a green to show each key, by MIDI number (1 = the next to play).
    var catchUp: [Int: Double] = [:]
    /// Called with the key's MIDI number when a key is touched (nil: the keyboard only shows).
    var onPress: ((Int) -> Void)?
    /// Called with the key's MIDI number when the finger lets go of it (or slides off it).
    var onRelease: ((Int) -> Void)?

    @State private var touchedKey: Int?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let renderer = KeyboardRenderer(layout: layout, glows: glows, hints: hints, now: now, showLetters: showLetters,
                                        catchUp: catchUp, isDark: colorScheme == .dark)
        GeometryReader { geo in
            Canvas { context, size in
                renderer.draw(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in touch(at: value.location, size: geo.size) }
                    .onEnded { _ in
                        if let key = touchedKey { onRelease?(key) }
                        touchedKey = nil
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Piano keyboard")
        .accessibilityValue(layout.keysInView)
        .accessibilityHint("Touch a key to play it")
    }

    /// Plays the key under the finger once, and again each time the finger slides onto another key.
    private func touch(at location: CGPoint, size: CGSize) {
        guard let onPress, let key = layout.key(at: location, size: size) else { return }
        if key != touchedKey {
            if let previous = touchedKey { onRelease?(previous) }
            touchedKey = key
            onPress(key)
        }
    }
}

/// Draws the keyboard; a plain value so the Canvas closure captures no view state.
struct KeyboardRenderer {
    let layout: KeyboardLayout
    let glows: [Int: KeyGlow]
    let hints: [Int: Double]
    let now: Double
    let showLetters: Bool
    var catchUp: [Int: Double] = [:]
    let isDark: Bool

    /// How strongly to show a hinted key right now: the key to press now flashes (about 3 times a second);
    /// keys still coming don't show at all, so nobody presses them early.
    private func hintLevel(_ midi: Int) -> Double? {
        // Catching up: green, fading from the key to play next (which flashes) to the last.
        if !catchUp.isEmpty { return catchUp[midi].map { CatchUpShade.shown($0, now: now) } }
        guard let closeness = hints[midi] else { return nil }
        return closeness >= 0.999 ? CatchUpShade.shown(1, now: now) : nil
    }

    /// Narrowest white key that gets its letter, and the narrowest where C keys also get their octave ("C4").
    static let letterMinimumWidth: CGFloat = 14
    static let octaveMinimumWidth: CGFloat = 22

    /// The keys of the chord coming next (the nearest one not due yet): outlined in steady blue, to get
    /// ready for without pressing. Not while catching up, which has its own order.
    private var preparing: Set<Int> {
        guard catchUp.isEmpty else { return [] }
        let coming = hints.filter { $0.value < 0.999 }
        guard let nearest = coming.values.max() else { return [] }
        return Set(coming.filter { $0.value >= nearest - 0.02 }.keys)
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let preparing = preparing
        context.clip(to: Path(CGRect(origin: .zero, size: size)))
        let white = layout.whiteKeyWidth(forWidth: size.width)
        let height = size.height
        let blackHeight = height * KeyboardLayout.blackKeyDepth
        let radius = min(8, white * 0.16)
        // Only the keys in view; the ones cut by the edges are drawn in part (the Canvas clips them).
        let keys = layout.visibleKeys

        // Key bed behind the gaps.
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: isDark ? 0.05 : 0.2)))

        // White keys, extended above the top so only their bottom corners look rounded.
        let whiteFill = Color(white: isDark ? 0.9 : 1)
        let letterSize = min(18, max(9, white * 0.36))
        let drawsLetters = showLetters && white >= Self.letterMinimumWidth
        let drawsOctaves = white >= Self.octaveMinimumWidth
        var letters: [String: GraphicsContext.ResolvedText] = [:]
        for midi in keys where !KeyboardLayout.isBlackKey(midi) {
            guard let span = layout.span(of: midi, width: size.width) else { continue }
            let rect = CGRect(x: span.x + 0.75, y: -radius, width: span.width - 1.5, height: height + radius - 1)
            let key = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
            let glow = glows[midi]
            context.fill(key, with: .color(whiteFill))
            if let glow {
                context.fill(key, with: .color(GameColors.color(for: glow).opacity(0.85)))
            } else if let level = hintLevel(midi) {
                context.fill(key, with: .color(GameColors.hint.opacity(0.9 * level)))
                context.stroke(Path(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerRadius: radius, style: .continuous),
                               with: .color(GameColors.hint.opacity(level)), lineWidth: 3)
            } else if preparing.contains(midi) {
                context.fill(key, with: .color(GameColors.prepare.opacity(0.15)))
                context.stroke(Path(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: radius, style: .continuous),
                               with: .color(GameColors.prepare), lineWidth: 3.5)
            }

            var markerY = height - max(10, white * 0.3)
            if drawsLetters {
                // Letters on every white key; C keys also say which octave they're in, to find your way.
                let spelled = NoteSpelling.spell(midi)
                let name = drawsOctaves && spelled.letter == "C" ? spelled.nameWithOctave : spelled.letter
                if letters[name] == nil {
                    let font = Font.system(size: letterSize, weight: .semibold, design: .rounded)
                    letters[name] = context.resolve(Text(name).font(font))
                }
                if var text = letters[name] {
                    text.shading = .color(glow == nil ? Color(white: 0.42) : .white)
                    let y = height - letterSize * 0.9 - 4
                    context.draw(text, at: CGPoint(x: span.midX, y: y), anchor: .center)
                    markerY = y - letterSize * 0.9 - 2
                }
            }
            if midi == 60 {
                // Middle C.
                let dot = min(10, max(5, white * 0.18))
                context.fill(Path(ellipseIn: CGRect(x: span.midX - dot / 2, y: markerY - dot / 2, width: dot, height: dot)),
                             with: .color(glow == nil ? Color.accentColor : .white))
            } else if let level = hintLevel(midi), glow == nil {
                let dot = min(12, max(6, white * 0.22)) * (0.7 + 0.3 * level)
                context.fill(Path(ellipseIn: CGRect(x: span.midX - dot / 2, y: markerY - dot / 2, width: dot, height: dot)),
                             with: .color(GameColors.hint))
            }
        }

        // Black keys.
        let blackTop = Color(white: isDark ? 0.2 : 0.28)
        let blackBottom = Color(white: isDark ? 0.02 : 0.06)
        for midi in keys where KeyboardLayout.isBlackKey(midi) {
            guard let span = layout.span(of: midi, width: size.width) else { continue }
            let r = min(4, span.width * 0.15)
            let rect = CGRect(x: span.x, y: -r, width: span.width, height: blackHeight + r)
            let key = Path(roundedRect: rect, cornerRadius: r, style: .continuous)
            if let glow = glows[midi] {
                context.fill(key, with: .color(GameColors.color(for: glow)))
            } else {
                context.fill(key, with: .linearGradient(Gradient(colors: [blackTop, blackBottom]),
                                                        startPoint: CGPoint(x: span.midX, y: 0),
                                                        endPoint: CGPoint(x: span.midX, y: blackHeight)))
                // A lighter front edge, like a real key (too fine to see on tiny keys).
                if span.width > 6 {
                    let lip = CGRect(x: span.x + 2, y: blackHeight - max(4, blackHeight * 0.06), width: span.width - 4,
                                     height: max(2, blackHeight * 0.04))
                    context.fill(Path(roundedRect: lip, cornerRadius: 1.5),
                                 with: .color(Color(white: 1, opacity: 0.12)))
                }
                if let level = hintLevel(midi) {
                    context.fill(key, with: .color(GameColors.hint.opacity(0.9 * level)))
                    context.stroke(Path(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerRadius: r, style: .continuous),
                                   with: .color(GameColors.hint.opacity(level)), lineWidth: 3)
                    let dot = min(10, max(5, span.width * 0.35))
                    context.fill(Path(ellipseIn: CGRect(x: span.midX - dot / 2, y: blackHeight - dot - 10,
                                                        width: dot, height: dot)),
                                 with: .color(GameColors.hint))
                } else if preparing.contains(midi) {
                    context.stroke(Path(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: r, style: .continuous),
                                   with: .color(GameColors.prepare), lineWidth: 3)
                }
            }
        }

        // A soft shadow along the top edge, where the keys disappear under the piano.
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 8)),
                     with: .linearGradient(Gradient(colors: [Color(white: 0, opacity: 0.35), Color(white: 0, opacity: 0)]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: 8)))
    }
}

/// The game's palette.
enum GameColors {
    static let rightHand = Color(red: 0.16, green: 0.6, blue: 0.96)
    static let leftHand = Color(red: 1, green: 0.56, blue: 0.16)
    static let hit = Color(red: 0.2, green: 0.8, blue: 0.36)
    static let early = Color(red: 1, green: 0.55, blue: 0.1)
    static let late = Color(red: 1, green: 0.8, blue: 0.1)
    static let wrong = Color(red: 0.95, green: 0.25, blue: 0.25)
    /// The keys to play next: green, like a hit, because that's what pressing them will be.
    static let hint = hit
    /// The keys after those: blue, get ready (yellow means late and red wrong, so neither of those).
    static let prepare = Color(red: 0.2, green: 0.55, blue: 1)
    /// Stars and scores.
    static let star = Color(red: 1, green: 0.8, blue: 0.1)

    static func color(for hand: Hand) -> Color { hand == .right ? rightHand : leftHand }

    static func color(for glow: KeyGlow) -> Color {
        switch glow {
        case .pressed: return .accentColor
        case .correct: return hit
        case .early: return early
        case .late: return late
        case .wrong: return wrong
        }
    }
}
