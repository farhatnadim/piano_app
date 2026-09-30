import PianoCoachCore
import SwiftUI

/// The whole piano in a thin strip above the keyboard, like the name board of a real piano: the part the
/// keyboard shows is framed, and the lit keys and the next keys to play show in colour, so the child sees
/// where on the real piano to put their hands. The mini keys fade away when the keyboard shows all 88 keys.
struct KeyboardMinimap: View {
    let layout: KeyboardLayout
    var glows: [Int: KeyGlow] = [:]
    var hints: [Int: Double] = [:]

    static let height: CGFloat = 18

    var body: some View {
        let renderer = MinimapRenderer(layout: layout, glows: glows, hints: hints)
        Canvas { context, size in
            renderer.draw(in: &context, size: size)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Where you are on the piano")
        .accessibilityValue(layout.keysInView)
        .accessibilityHidden(layout.showsWholeKeyboard)
    }
}

/// Draws the minimap; a plain value so the Canvas closure captures no view state.
struct MinimapRenderer {
    let layout: KeyboardLayout
    let glows: [Int: KeyGlow]
    let hints: [Int: Double]

    /// How much the mini keys show: not at all with the whole keyboard in view, fully once zoomed in a little.
    var visibility: Double {
        min(1, max(0, (Double(KeyboardLayout.whiteKeyTotal) - layout.visibleWhiteKeys) / 6))
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        // The piano's body (dark in light and dark mode alike), with a strip of red felt where the keys go in.
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.12)))
        context.fill(Path(CGRect(x: 0, y: size.height - 2, width: size.width, height: 2)),
                     with: .color(Color(red: 0.5, green: 0.08, blue: 0.1)))

        let area = CGRect(x: 8, y: 3, width: size.width - 16, height: size.height - 7)
        guard visibility > 0, area.width >= CGFloat(KeyboardLayout.whiteKeyTotal), area.height > 4 else { return }
        context.opacity = visibility
        let key = area.width / CGFloat(KeyboardLayout.whiteKeyTotal)
        func x(_ position: Double) -> CGFloat { area.minX + CGFloat(position) * key }

        let gap = min(1, key * 0.14)
        for (index, midi) in KeyboardLayout.whiteKeyMIDI.enumerated() {
            let rect = CGRect(x: x(Double(index)) + gap / 2, y: area.minY, width: key - gap, height: area.height)
            context.fill(Path(rect), with: .color(color(for: midi) ?? Color(white: 0.93)))
        }
        for midi in KeyboardLayout.lowestKey...KeyboardLayout.highestKey where KeyboardLayout.isBlackKey(midi) {
            let extent = KeyboardLayout.extent(of: midi)
            let rect = CGRect(x: x(extent.lowerBound), y: area.minY,
                              width: CGFloat(extent.upperBound - extent.lowerBound) * key, height: area.height * 0.6)
            context.fill(Path(rect), with: .color(color(for: midi) ?? Color(white: 0.08)))
        }

        // Middle C.
        let middleC = KeyboardLayout.extent(of: 60)
        let dot = max(2.5, min(4, key * 0.5))
        let dotX = x((middleC.lowerBound + middleC.upperBound) / 2)
        context.fill(Path(ellipseIn: CGRect(x: dotX - dot / 2, y: area.maxY - dot - 1.5, width: dot, height: dot)),
                     with: .color(Color.accentColor))

        // Shade the keys out of view and frame the ones in view.
        let left = x(layout.visibleStart)
        let right = x(layout.visibleEnd)
        let shade = Color(white: 0, opacity: 0.5)
        context.fill(Path(CGRect(x: area.minX, y: area.minY, width: max(0, left - area.minX), height: area.height)),
                     with: .color(shade))
        context.fill(Path(CGRect(x: right, y: area.minY, width: max(0, area.maxX - right), height: area.height)),
                     with: .color(shade))
        let frame = CGRect(x: left - 1, y: area.minY - 1.5, width: right - left + 2, height: area.height + 3)
        context.stroke(Path(roundedRect: frame, cornerRadius: 3, style: .continuous), with: .color(.white),
                       lineWidth: 2)
    }

    private func color(for midi: Int) -> Color? {
        if let glow = glows[midi] { return GameColors.color(for: glow) }
        if hints[midi] != nil { return GameColors.hint }
        return nil
    }
}

/// Small round buttons in the corner of the play area: the song's keys held still, follow the song (zoomed
/// in on the keys being played), or all 88 keys. The choice is remembered.
struct KeyboardZoomPicker: View {
    @AppStorage(KeyboardZoom.storageKey) private var zoom = KeyboardZoom.song

    var body: some View {
        HStack(spacing: 2) {
            ForEach(KeyboardZoom.allCases) { option in
                let isOn = zoom == option
                Button { zoom = option } label: {
                    Image(systemName: option.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .frame(width: 36, height: 32)
                        .background { Capsule().fill(isOn ? Color.accentColor : Color.clear) }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .gameHoverEffect()
                .help(option.displayName)
                .accessibilityLabel(option.displayName)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.primary.opacity(0.08)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard")
    }
}
