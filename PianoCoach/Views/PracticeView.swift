import PianoCoachCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The practice screen: the video with big controls underneath and the sheet music beside or below it.
///
/// Nothing is ever drawn on top of the YouTube player (YouTube's rules); the toast and banners live in
/// the controls area and over the sheet music.
struct PracticeView: View {
    @Environment(AppModel.self) private var model
    /// Created in `.task` rather than as the property's initial value: SwiftUI evaluates `@State` initial
    /// values every time it re-creates this view value, which would build (and throw away) a web view each time.
    @State private var sheet: SheetMusicController?
    @State private var showSetup = false

    var body: some View {
        GeometryReader { geo in
            let beside = model.showSheet && showsSheetBeside(in: geo.size)
            let metrics = PracticeMetrics(size: geo.size, beside: beside, showSheet: model.showSheet)
            // One layout whose children keep their identity when switching between beside and below,
            // so the player's web view is never re-created.
            let layout = beside ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
                                : AnyLayout(VStackLayout(spacing: 0))
            layout {
                playerColumn(metrics)
                if model.showSheet {
                    SheetPanel(controller: sheet) { showSetup = true }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .overlay(alignment: .bottom) {
            ToastOverlay()
        }
        .navigationTitle(model.openPiece?.title ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSetup = true } label: {
                    Label("Set up", systemImage: "slider.horizontal.3")
                }
                .help("Sheet music, tempo, lining up and teaching the coach")
            }
        }
        .sheet(isPresented: $showSetup) {
            PieceSetupView()
                .environment(model)
        }
        .task {
            if sheet == nil { sheet = SheetMusicController() }
        }
    }

    private func playerColumn(_ metrics: PracticeMetrics) -> some View {
        VStack(spacing: 0) {
            WebViewContainer(webView: model.player.webView)
                .frame(width: metrics.video.width, height: metrics.video.height)
                .background(Color.black)
                .frame(maxWidth: .infinity)
                .padding(.top, metrics.videoInset)
            if metrics.scrollsControls {
                ScrollView {
                    controls(metrics)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                controls(metrics)
            }
        }
        .frame(width: metrics.columnWidth)
        .frame(maxHeight: metrics.scrollsControls ? .infinity : nil, alignment: .top)
    }

    private func controls(_ metrics: PracticeMetrics) -> some View {
        VStack(spacing: metrics.compact ? 10 : 14) {
            PracticeBanners()
            TransportBar(compact: metrics.compact)
            CoachModePicker()
            CoachStatusBar()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, metrics.compact ? 10 : 14)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    private func showsSheetBeside(in size: CGSize) -> Bool {
        switch model.settings.sheetLayout {
        case .beside: return size.width >= 600
        case .below: return false
        case .automatic: return size.width >= 700 && size.width > size.height * 1.15
        }
    }
}

// MARK: - Layout

/// Sizes for the practice screen: a 16:9 video (at least 200×200, as YouTube requires) that leaves room
/// for the controls and, below it, for the music.
private struct PracticeMetrics {
    /// Approximate height of the controls under the video (without banners).
    static let controlsHeight: CGFloat = 210

    let video: CGSize
    let columnWidth: CGFloat?
    let videoInset: CGFloat
    /// The controls scroll inside a column that fills the height (no music below).
    let scrollsControls: Bool
    let compact: Bool

    init(size: CGSize, beside: Bool, showSheet: Bool) {
        let availableWidth: CGFloat
        let maxHeight: CGFloat
        if beside {
            let column = min(max(size.width * 0.45, 340), 640)
            columnWidth = column
            videoInset = 16
            availableWidth = column - 32
            maxHeight = size.height - Self.controlsHeight - videoInset
        } else {
            columnWidth = nil
            videoInset = size.width >= 600 ? 16 : 0
            availableWidth = size.width - 2 * videoInset
            // With the music below, the video takes at most half of what the controls leave.
            maxHeight = showSheet ? (size.height - Self.controlsHeight) * 0.5 : size.height - Self.controlsHeight - videoInset
        }
        var width = availableWidth
        var height = width * 9 / 16
        if height > maxHeight {
            height = maxHeight
            width = height * 16 / 9
        }
        if height < 200 {
            height = 200
            width = min(availableWidth, height * 16 / 9)
        }
        video = CGSize(width: max(200, width.rounded()), height: height.rounded())
        scrollsControls = beside || !showSheet
        compact = min(columnWidth ?? size.width, 720) - 32 < 440
    }
}

// MARK: - Controls

/// Back, play/pause, skip, speed, loop and music.
private struct TransportBar: View {
    @Environment(AppModel.self) private var model
    let compact: Bool

    var body: some View {
        let coach = model.coach
        let size: CGFloat = compact ? 44 : 52
        HStack(spacing: compact ? 6 : 12) {
            SpeedControl(size: size)
            Spacer(minLength: 4)
            Button { coach.goBack() } label: {
                RoundControlLabel(systemImage: "gobackward", caption: "Back", size: size)
            }
            .macKeyboardShortcut(.leftArrow)
            Button { coach.togglePlayPause() } label: {
                RoundControlLabel(systemImage: willPause ? "pause.fill" : "play.fill",
                                  caption: willPause ? "Pause" : "Play", size: size + 12, prominent: true)
            }
            .macKeyboardShortcut(.space)
            .disabled(!model.player.isReady)
            Button { coach.skip(by: 5) } label: {
                RoundControlLabel(systemImage: "goforward.5", caption: "Skip", size: size)
            }
            .macKeyboardShortcut(.rightArrow)
            Spacer(minLength: 4)
            Button(action: toggleLoop) {
                RoundControlLabel(systemImage: "repeat", caption: "Loop", size: size, isOn: coach.loop != nil)
            }
            Button { model.showSheet.toggle() } label: {
                RoundControlLabel(systemImage: "music.note.list", caption: "Music", size: size, isOn: model.showSheet)
            }
        }
        .buttonStyle(PressableButtonStyle())
    }

    /// Mirrors `CoachEngine.togglePlayPause()`: shows "pause" whenever pressing would pause.
    private var willPause: Bool {
        let coach = model.coach
        return model.player.isPlaying
            || (coach.mode == .followMe && coach.status != .pausedByUser && coach.status != .idle)
    }

    private func toggleLoop() {
        let coach = model.coach
        if coach.loop != nil {
            coach.loop = nil
            model.showToast("Loop off")
        } else {
            coach.loopHere()
            model.showToast("Looping this part")
        }
    }
}

/// The speed button: a menu on iPhone/iPad, a popover on the Mac (where menus can't show a custom label).
private struct SpeedControl: View {
    @Environment(AppModel.self) private var model
    let size: CGFloat
    #if os(macOS)
    @State private var showRates = false
    #endif

    var body: some View {
        // `speedSetting` isn't observable by itself; the applied rate and the mode are.
        let _ = (model.player.rate, model.coach.mode)
        let current = model.coach.speedSetting
        #if os(iOS)
        Menu {
            Section(title) {
                ForEach(rates, id: \.self) { rate in
                    Button { model.setSpeed(rate) } label: {
                        if abs(rate - current) < 0.001 {
                            Label(speedName(rate), systemImage: "checkmark")
                        } else {
                            Text(speedName(rate))
                        }
                    }
                }
            }
        } label: {
            RoundControlLabel(systemImage: symbol(for: current), caption: speedName(current), size: size,
                              isOn: abs(current - 1) > 0.001)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Speed, \(speedName(current))")
        #else
        Button { showRates = true } label: {
            RoundControlLabel(systemImage: symbol(for: current), caption: speedName(current), size: size,
                              isOn: abs(current - 1) > 0.001)
        }
        .accessibilityLabel("Speed, \(speedName(current))")
        .help("Video speed")
        .popover(isPresented: $showRates, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                ForEach(rates, id: \.self) { rate in
                    Button {
                        model.setSpeed(rate)
                        showRates = false
                    } label: {
                        HStack {
                            Image(systemName: "checkmark")
                                .opacity(abs(rate - current) < 0.001 ? 1 : 0)
                            Text(speedName(rate))
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .frame(minWidth: 180)
        }
        #endif
    }

    /// Fastest first, like a volume list.
    private var rates: [Double] { Array(model.coach.availableRates.reversed()) }

    private var title: String {
        model.coach.mode == .followMe ? "Fastest the video may go" : "Video speed"
    }

    private func symbol(for rate: Double) -> String {
        if rate < 0.999 { return "tortoise.fill" }
        if rate > 1.001 { return "hare.fill" }
        return "speedometer"
    }
}

/// Off / Wait for me / Follow me.
private struct CoachModePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let appModel = model
        Picker("Coach", selection: Binding(get: { appModel.coach.mode }, set: { appModel.setPreferredMode($0) })) {
            ForEach(CoachMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 480)
    }
}

/// What the coach is doing, the child's speed, and whether the microphone and voice commands are on.
private struct CoachStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let coach = model.coach
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(coach.status))
                    .frame(width: 10, height: 10)
                Text(coach.status.message)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if coach.mode == .followMe, let percent = coach.childSpeedPercent {
                    Text(verbatim: "· your speed \(percent)%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if coach.isListening {
                    ListeningIndicator()
                }
                if model.voice.isRunning {
                    VoiceIndicator()
                }
            }
            if model.voice.isRunning {
                VoiceTranscriptLine()
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func statusColor(_ status: PacingStatus) -> Color {
        switch status {
        case .idle: return .secondary
        case .waitingToStart: return .blue
        case .playingAlong, .jumpedToChild: return .green
        case .pausedForSilence, .pausedAhead: return .orange
        case .pausedByUser: return .gray
        }
    }
}

/// Microphone/MIDI level with a note that bounces on every heard note.
private struct ListeningIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let coach = model.coach
        HStack(spacing: 6) {
            Image(systemName: coach.noteSource == .midiKeyboard ? "pianokeys" : "music.note")
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: coach.heardCount)
            if coach.noteSource == .midiKeyboard, !coach.lastHeard.isEmpty {
                Text(coach.lastHeard)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            LevelMeter(level: coach.inputLevel)
                .frame(width: 56)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(coach.noteSource == .midiKeyboard ? "Listening to the keyboard" : "Listening to the piano"))
    }
}

/// A microphone that bounces whenever speech is heard.
private struct VoiceIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Image(systemName: "mic.fill")
            .foregroundStyle(.tint)
            .symbolEffect(.bounce, value: model.voice.lastTranscript)
            .help(Text(model.settings.requireWakeWord ? "Listening for “Coach, …”" : "Listening for voice commands"))
            .accessibilityLabel("Listening for voice commands")
    }
}

/// The last words the voice listener heard.
private struct VoiceTranscriptLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let heard = nonEmpty(model.voice.lastTranscript) {
            Text("“\(heard)”")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("Heard: \(heard)")
        }
    }
}

// MARK: - Banners and toast

/// Messages for the parent/child, shown between the video and the controls.
private struct PracticeBanners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let coach = model.coach
        let player = model.player
        Group {
            if coach.isLearning {
                NoticeBanner("Learning the song… \(coach.learnedNoteCount) notes so far. Keep the room quiet.",
                             systemImage: "ear", accessory: {
                    HStack {
                        Button("Stop & save") { _ = coach.finishLearning() }
                            .buttonStyle(.borderedProminent)
                        Button("Cancel") { coach.cancelLearning() }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                })
            }
            if player.autoplayBlocked {
                NoticeBanner("Tap the video once to let it play.", systemImage: "hand.tap.fill")
            }
            if let error = player.errorMessage {
                NoticeBanner(error, style: .error, accessory: {
                    if let videoID = player.videoID ?? model.openPiece?.videoID {
                        Link(destination: YouTubeLink.watchURL(videoID: videoID)) {
                            Label("Open in YouTube", systemImage: "arrow.up.right.square")
                        }
                    }
                })
            }
            if let error = coach.listeningError {
                NoticeBanner(error, style: .warning, systemImage: "mic.slash.fill", accessory: {
                    if error == AudioInputHub.HubError.permissionDenied.localizedDescription,
                       let url = Self.privacySettingsURL {
                        Link("Open Settings", destination: url)
                    }
                })
            }
            if let error = nonEmpty(model.voice.errorMessage), error != coach.listeningError {
                NoticeBanner(error, style: .warning, systemImage: "mic.slash", accessory: {
                    if error == AudioInputHub.HubError.permissionDenied.localizedDescription,
                       let url = Self.privacySettingsURL {
                        Link("Open Settings", destination: url)
                    }
                })
            }
            if let notice = coach.notice, !coach.isLearning {
                NoticeBanner(notice, onDismiss: { coach.clearNotice() })
            }
        }
    }

    private static var privacySettingsURL: URL? {
        #if os(iOS)
        return URL(string: UIApplication.openSettingsURLString)
        #else
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #endif
    }
}

/// The voice-command confirmation, near the bottom of the screen (never over the video).
private struct ToastOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let toast = model.toast {
                ToastView(text: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.toast)
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .allowsHitTesting(false)
    }
}
