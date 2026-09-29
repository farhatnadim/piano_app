import PianoCoachCore
import SwiftUI

/// A piano keyboard drawn in one Canvas, with key glows (held, right, wrong), a gentle hint on the keys to
/// play next, letter names and a mark on middle C. It shows the part of the 88 keys in `layout`'s window
/// (all of them, or the part the song is played on). Tapping or sliding across it plays keys.
struct PianoKeyboardView: View {
    let layout: KeyboardLayout
    var glows: [Int: KeyGlow] = [:]
    var hints: Set<Int> = []
    var showLetters = true
    /// Called with the key's MIDI number when a key is touched (nil: the keyboard only shows).
    var onPress: ((Int) -> Void)?

    @State private var touchedKey: Int?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let renderer = KeyboardRenderer(layout: layout, glows: glows, hints: hints, showLetters: showLetters,
                                        isDark: colorScheme == .dark)
        GeometryReader { geo in
            Canvas { context, size in
                renderer.draw(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in touch(at: value.location, size: geo.size) }
                    .onEnded { _ in touchedKey = nil }
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
            touchedKey = key
            onPress(key)
        }
    }
}

/// Draws the keyboard; a plain value so the Canvas closure captures no view state.
struct KeyboardRenderer {
    let layout: KeyboardLayout
    let glows: [Int: KeyGlow]
    let hints: Set<Int>
    let showLetters: Bool
    let isDark: Bool

    /// Narrowest white key that gets its letter, and the narrowest where C keys also get their octave ("C4").
    static let letterMinimumWidth: CGFloat = 14
    static let octaveMinimumWidth: CGFloat = 22

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
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
            } else if hints.contains(midi) {
                context.fill(key, with: .color(GameColors.hint.opacity(0.28)))
                context.stroke(Path(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerRadius: radius, style: .continuous),
                               with: .color(GameColors.hint), lineWidth: 3)
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
            } else if hints.contains(midi), glow == nil {
                let dot = min(12, max(6, white * 0.22))
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
                if hints.contains(midi) {
                    context.stroke(Path(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerRadius: r, style: .continuous),
                                   with: .color(GameColors.hint), lineWidth: 3)
                    let dot = min(10, max(5, span.width * 0.35))
                    context.fill(Path(ellipseIn: CGRect(x: span.midX - dot / 2, y: blackHeight - dot - 10,
                                                        width: dot, height: dot)),
                                 with: .color(GameColors.hint))
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
    static let wrong = Color(red: 0.95, green: 0.25, blue: 0.25)
    static let hint = Color(red: 1, green: 0.8, blue: 0.1)

    static func color(for hand: Hand) -> Color { hand == .right ? rightHand : leftHand }

    static func color(for glow: KeyGlow) -> Color {
        switch glow {
        case .pressed: return .accentColor
        case .correct: return hit
        case .wrong: return wrong
        }
    }
}
