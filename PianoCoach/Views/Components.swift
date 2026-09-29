import PianoCoachCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Level meter

/// A small horizontal bar showing the input level (0...1).
struct LevelMeter: View {
    var level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, level))))
            }
        }
        .frame(height: 8)
        .animation(.linear(duration: 0.1), value: level)
        .accessibilityElement()
        .accessibilityLabel("Sound level")
        .accessibilityValue("\(Int((max(0, min(1, level)) * 100).rounded())) percent")
    }
}

// MARK: - Toast

/// A short confirmation ("Slower") shown after a voice command.
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.quaternary) }
            .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }
}

// MARK: - Banner

/// A rounded message box for notices and errors, with an optional dismiss button and accessory
/// (a link or buttons) underneath the text.
struct NoticeBanner<Accessory: View>: View {
    enum Style {
        case info, warning, error

        var tint: Color {
            switch self {
            case .info: return .blue
            case .warning: return .orange
            case .error: return .red
            }
        }

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }
    }

    let text: String
    var style: Style
    var systemImage: String?
    var onDismiss: (() -> Void)?
    let accessory: Accessory

    init(_ text: String, style: Style = .info, systemImage: String? = nil, onDismiss: (() -> Void)? = nil,
         @ViewBuilder accessory: () -> Accessory) {
        self.text = text
        self.style = style
        self.systemImage = systemImage
        self.onDismiss = onDismiss
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage ?? style.symbol)
                .foregroundStyle(style.tint)
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                accessory
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style.tint.opacity(0.3))
        }
    }
}

extension NoticeBanner where Accessory == EmptyView {
    init(_ text: String, style: Style = .info, systemImage: String? = nil, onDismiss: (() -> Void)? = nil) {
        self.init(text, style: style, systemImage: systemImage, onDismiss: onDismiss) { EmptyView() }
    }
}

// MARK: - Buttons

/// Shrinks the label a little while pressed.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Helpers

extension View {
    /// Adds a keyboard shortcut without modifiers on the Mac only (on iPad a bare key could steal typing).
    @ViewBuilder
    func macKeyboardShortcut(_ key: KeyEquivalent) -> some View {
        #if os(macOS)
        keyboardShortcut(key, modifiers: [])
        #else
        self
        #endif
    }
}

/// "1:05" (or "1:05.3" with tenths).
func timeText(_ seconds: Double, tenths: Bool = false) -> String {
    let s = max(0, seconds.isFinite ? seconds : 0)
    let minutes = Int(s) / 60
    let rest = s - Double(minutes * 60)
    if tenths {
        let tenthsValue = Int((rest * 10).rounded(.down))
        return String(format: "%d:%02d.%d", minutes, tenthsValue / 10, tenthsValue % 10)
    }
    return String(format: "%d:%02d", minutes, Int(rest))
}

/// The text if it has something besides whitespace. Accepts optional and non-optional strings.
func nonEmpty(_ text: String?) -> String? {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return text
}

/// The piece's YouTube thumbnail, cropped to 16:9.
struct VideoThumbnail: View {
    let videoID: String
    var width: CGFloat = 96

    var body: some View {
        AsyncImage(url: YouTubeLink.thumbnailURL(videoID: videoID)) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }
}
