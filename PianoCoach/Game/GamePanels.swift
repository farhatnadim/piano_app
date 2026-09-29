import PianoCoachCore
import SwiftUI

// MARK: - Heads-up display

/// The bar above the notes: pause, mode, score, combo, speed and progress. Kept light so the notes stay
/// the focus.
struct GameHUD: View {
    let game: GameController
    /// Narrow screens drop the mode label.
    var compact = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: compact ? 8 : 14) {
                Button { game.togglePause() } label: {
                    Image(systemName: game.phase == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 44, height: 44)
                        .background { Circle().fill(.quaternary) }
                        .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .macKeyboardShortcut(.space)
                .disabled(game.phase == .finished)
                .gameHoverEffect()
                .help("Pause (space)")
                .accessibilityLabel(game.phase == .paused ? "Resume" : "Pause")

                if !compact {
                    Text("\(game.mode.displayName) · \(game.hands.displayName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(GameColors.hint)
                    Text(verbatim: "\(game.score)")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .font(.title3.weight(.bold))
                .animation(.easeOut(duration: 0.2), value: game.score)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Score \(game.score)")
                if game.combo >= 2 {
                    Text(verbatim: "×\(game.combo)")
                        .font(.headline.weight(.heavy))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background { Capsule().fill(GameColors.leftHand) }
                        .accessibilityLabel("\(game.combo) in a row")
                }
                SpeedBadge(game: game)
            }
            .padding(.horizontal, 12)
            .frame(height: 56)
            GameProgressBar(game: game)
        }
    }
}

/// The current speed with a tortoise (slower than the song) or a hare.
struct SpeedBadge: View {
    let game: GameController

    var body: some View {
        let percent = Int((game.speed * 100).rounded())
        HStack(spacing: 4) {
            Image(systemName: game.speed < 0.995 ? "tortoise.fill" : "hare.fill")
            Text(verbatim: "\(percent) %")
                .monospacedDigit()
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speed \(percent) percent")
    }
}

/// How much of the song has been played.
struct GameProgressBar: View {
    let game: GameController

    var body: some View {
        let progress = CGFloat(max(0, min(1, game.progress)))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.quaternary)
                Rectangle()
                    .fill(LinearGradient(colors: [GameColors.rightHand, Color.accentColor],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * progress)
            }
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

/// "Perfect!", "10 in a row!": pops up for a moment.
struct CheerBubble: View {
    let game: GameController

    var body: some View {
        ZStack {
            if let cheer = game.cheer {
                Text(cheer.text)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background {
                        Capsule().fill(LinearGradient(colors: [Color.accentColor, GameColors.rightHand],
                                                      startPoint: .leading, endPoint: .trailing))
                    }
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                    .id(cheer.id)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: game.cheer)
        .allowsHitTesting(false)
    }
}

/// Shown instead of the HUD while the built-in piano plays the song.
struct DemoBar: View {
    let game: GameController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "ear.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text("Listen to the song…")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { game.stopDemo() } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.headline)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .macKeyboardShortcut(.space)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            GameProgressBar(game: game)
        }
    }
}

// MARK: - Start

/// Before a game: the big Start button and the choices (mode, hands, view, letters, speed).
struct StartPanel: View {
    @Environment(AppModel.self) private var model
    @Bindable var game: GameController
    let chart: NoteChart
    /// Opens the piece's setup, to add sheet music.
    var onAddSheetMusic: () -> Void

    var body: some View {
        CenteredScroll {
            GameCard {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if chart.source == .listening {
                        NoticeBanner("Made by listening to the video — some notes may be off. Add sheet music for exact notes.",
                                     systemImage: "ear", accessory: {
                            Button("Add sheet music", action: onAddSheetMusic)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        })
                    }
                    HStack(spacing: 12) {
                        modeTile(.learn, systemImage: "graduationcap.fill", explanation: "The notes wait for you")
                        modeTile(.play, systemImage: "bolt.fill", explanation: "Keep up and score points")
                    }
                    buttons
                    options
                    speed
                    inputLine
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.openPiece?.title ?? chart.title)
                .font(.title2.weight(.bold))
                .lineLimit(2)
            HStack(spacing: 16) {
                if let level = game.difficulty?.level {
                    HStack(spacing: 6) {
                        Text("Difficulty")
                            .foregroundStyle(.secondary)
                        StarRow(count: 5, filled: level, size: 13, color: GameColors.leftHand)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Difficulty \(level) of 5")
                }
                if let progress = model.openPiece?.game, progress.gamesPlayed > 0 {
                    HStack(spacing: 6) {
                        Text("Best")
                            .foregroundStyle(.secondary)
                        StarRow(count: 3, filled: progress.bestStars, size: 15)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Best \(progress.bestStars) of 3 stars")
                }
            }
            .font(.subheadline)
        }
    }

    private func modeTile(_ mode: GameMode, systemImage: String, explanation: String) -> some View {
        let selected = game.mode == mode
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return Button { game.mode = mode } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(mode.displayName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.primary)
                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(14)
            .background { shape.fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)) }
            .overlay { shape.strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2.5) }
            .contentShape(shape)
        }
        .buttonStyle(PressableButtonStyle())
        .gameHoverEffect()
        .accessibilityLabel("\(mode.displayName): \(explanation)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Side by side when there's room (iPad, Mac), one above the other on iPhone.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    handsPicker
                    displayPicker
                }
                VStack(alignment: .leading, spacing: 14) {
                    handsPicker
                    displayPicker
                }
            }
            if game.hands != .both {
                Toggle("The piano plays the other hand", isOn: $game.accompanyOtherHand)
                    .toggleStyle(.switch)
            }
            Toggle("Letter names (C D E…)", isOn: $game.showLetters)
                .toggleStyle(.switch)
        }
    }

    private var handsPicker: some View {
        OptionRow(title: "Hands", systemImage: "hand.raised.fill") {
            Picker("Hands", selection: $game.hands) {
                Text("Both").tag(HandSelection.both)
                Text("Right").tag(HandSelection.right)
                Text("Left").tag(HandSelection.left)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var displayPicker: some View {
        OptionRow(title: "Show", systemImage: "eye.fill") {
            Picker("Show", selection: $game.display) {
                Text("Keys").tag(GameDisplay.keys)
                Text("Notes").tag(GameDisplay.notes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var speed: some View {
        let controller = game
        let speed = controller.startSpeed
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Speed", systemImage: "speedometer")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "Level \(Int((speed * 10).rounded())) · \(Int((speed * 100).rounded())) %")
                    .font(.headline)
                    .monospacedDigit()
            }
            HStack(spacing: 10) {
                Image(systemName: "tortoise.fill")
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { controller.startSpeed }, set: { controller.setSpeed($0) }),
                       in: 0.3...1.2, step: 0.05)
                    .accessibilityLabel("Speed")
                    .accessibilityValue("Level \(Int((speed * 10).rounded()))")
                Image(systemName: "hare.fill")
                    .foregroundStyle(.secondary)
            }
            Toggle("Follow my speed (faster when it goes well, slower when it's hard)", isOn: $game.adaptiveSpeed)
                .toggleStyle(.switch)
                .font(.subheadline)
        }
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button { game.start() } label: {
                Label("Start", systemImage: "play.fill")
                    .font(.title2.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .macKeyboardShortcut(.space)
            .help("Start (space)")
            Button { game.playDemo() } label: {
                Label("Listen first", systemImage: "ear")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
    }

    private var inputLine: some View {
        let coach = model.coach
        let usesMIDI = coach.noteSource == .midiKeyboard
        return VStack(alignment: .leading, spacing: 8) {
            Label(usesMIDI ? "Playing on a MIDI keyboard" : "Listening with the microphone",
                  systemImage: usesMIDI ? "pianokeys" : "mic.fill")
                .font(.subheadline.weight(.semibold))
            if !usesMIDI {
                Text("Tip: a MIDI keyboard is the most accurate. You can choose it in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("You can also tap the keys on the screen, or type A W S E D F T G Y H U J K on a keyboard.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let error = coach.listeningError {
                NoticeBanner(error, style: .warning, systemImage: "mic.slash.fill")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A titled control in the start panel.
private struct OptionRow<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

// MARK: - Count-in, pause, results

/// The huge 3, 2, 1 before the notes start.
struct CountInOverlay: View {
    let number: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.15)
            VStack(spacing: 4) {
                Text(verbatim: "\(number)")
                    .font(.system(size: 150, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: Color.accentColor.opacity(0.8), radius: 20)
                    .id(number)
                    .transition(.scale(scale: 1.8).combined(with: .opacity))
                Text("Get ready…")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 4)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: number)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(number)")
    }
}

/// Resume, restart or quit, and a speed change for when it's too fast.
struct PausedPanel: View {
    let game: GameController
    /// The speed the game will ease into when it resumes.
    @State private var speed: Double?

    var body: some View {
        let current = speed ?? game.speed
        ZStack {
            Color.black.opacity(0.35)
            CenteredScroll {
                GameCard {
                    VStack(spacing: 18) {
                        Text("Paused")
                            .font(.largeTitle.weight(.bold))
                        HStack(spacing: 16) {
                            stepButton(systemImage: "tortoise.fill", label: "Slower", by: -0.05, from: current)
                            Text(verbatim: "\(Int((current * 100).rounded())) %")
                                .font(.title2.weight(.bold))
                                .monospacedDigit()
                                .frame(minWidth: 80)
                            stepButton(systemImage: "hare.fill", label: "Faster", by: 0.05, from: current)
                        }
                        Button { game.resume() } label: {
                            Label("Resume", systemImage: "play.fill")
                                .font(.title2.weight(.bold))
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        HStack(spacing: 12) {
                            Button { game.restart() } label: {
                                Label("Restart", systemImage: "arrow.counterclockwise")
                                    .frame(maxWidth: .infinity, minHeight: 36)
                            }
                            Button { game.stop() } label: {
                                Label("Quit", systemImage: "xmark")
                                    .frame(maxWidth: .infinity, minHeight: 36)
                            }
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .font(.headline)
                    }
                }
            }
        }
    }

    private func stepButton(systemImage: String, label: String, by step: Double, from current: Double) -> some View {
        Button {
            let next = max(0.3, min(1.2, ((current + step) * 20).rounded() / 20))
            speed = next
            game.setSpeed(next)
        } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 52, height: 52)
                .background { Circle().fill(.quaternary) }
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .gameHoverEffect()
        .accessibilityLabel(label)
    }
}

/// Stars, accuracy and counts after a game, with what happens to the level next time.
struct ResultsPanel: View {
    let game: GameController
    let result: GameResult
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            CenteredScroll {
                GameCard {
                    VStack(spacing: 18) {
                        Text(title)
                            .font(.largeTitle.weight(.heavy))
                            .multilineTextAlignment(.center)
                        stars
                        VStack(spacing: 0) {
                            Text(verbatim: "\(Int((result.accuracy * 100).rounded())) %")
                                .font(.system(size: 48, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                            Text("of the notes right")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            StatTile(value: result.perfect, label: "Perfect", color: GameColors.hit)
                            StatTile(value: result.good, label: "Good", color: GameColors.rightHand)
                            StatTile(value: result.missed, label: "Missed", color: GameColors.leftHand)
                            StatTile(value: result.wrongNotes, label: "Wrong", color: GameColors.wrong)
                        }
                        HStack(spacing: 18) {
                            Label("Best combo ×\(result.maxCombo)", systemImage: "flame.fill")
                            Label("Speed \(Int((result.endSpeed * 100).rounded())) %",
                                  systemImage: result.endSpeed < 0.995 ? "tortoise.fill" : "hare.fill")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        if let message = levelMessage {
                            Label(message.text, systemImage: message.symbol)
                                .font(.headline)
                                .foregroundStyle(message.color)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .background(message.color.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        VStack(spacing: 10) {
                            Button { game.restart() } label: {
                                Label("Play again", systemImage: "arrow.counterclockwise")
                                    .font(.title2.weight(.bold))
                                    .frame(maxWidth: .infinity, minHeight: 50)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .macKeyboardShortcut(.space)
                            Button { game.closeResults() } label: {
                                Text("Done")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                        }
                    }
                }
            }
        }
        .onAppear { appeared = true }
    }

    private var title: String {
        switch result.stars {
        case 3: return "Amazing!"
        case 2: return "Great job!"
        case 1: return "Nice try!"
        default: return "Good effort!"
        }
    }

    /// Three stars popping in one after another.
    private var stars: some View {
        HStack(spacing: 14) {
            ForEach(0..<3, id: \.self) { i in
                let earned = i < result.stars
                Image(systemName: earned ? "star.fill" : "star")
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(earned ? GameColors.hint : Color.secondary.opacity(0.4))
                    .shadow(color: earned ? GameColors.hint.opacity(0.6) : .clear, radius: 10)
                    .scaleEffect(appeared ? 1 : 0.2)
                    .opacity(appeared ? 1 : 0)
                    .rotationEffect(.degrees(appeared ? 0 : -60))
                    .animation(.spring(response: 0.5, dampingFraction: 0.5).delay(0.2 + Double(i) * 0.3), value: appeared)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(result.stars) of 3 stars")
    }

    private var levelMessage: (text: String, symbol: String, color: Color)? {
        switch game.levelChange {
        case .up(let speed)?:
            return ("Level up! Next time: \(Int((speed * 100).rounded())) %", "arrow.up.circle.fill", GameColors.hit)
        case .down?:
            return ("Next time we'll go a little slower", "tortoise.fill", GameColors.leftHand)
        case .same?:
            return ("Keep practising!", "hand.thumbsup.fill", GameColors.rightHand)
        case nil:
            return nil
        }
    }
}

/// One count in the results ("12 Perfect").
private struct StatTile: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(verbatim: "\(value)")
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - No song yet

/// The game needs the song's notes: listen to the video, or add sheet music.
struct NoSongPanel: View {
    @Environment(AppModel.self) private var model
    var onAddSheetMusic: () -> Void

    var body: some View {
        CenteredScroll {
            GameCard {
                VStack(spacing: 18) {
                    Image(systemName: "music.quarternote.3")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text("Let's get the notes!")
                        .font(.title.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("The game needs this song's notes. Piano Coach can listen to the video and work them out, or you can add sheet music for exact notes.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { model.buildGameByListening() } label: {
                        Label("Listen to the video to make the game", systemImage: "ear")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    Button(action: onAddSheetMusic) {
                        Label("Add sheet music (MIDI or MusicXML)", systemImage: "doc.badge.plus")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    Text("Listening works best in a quiet room, while the video plays once from start to end.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Building blocks

/// A rounded card for the game's panels: centred and at most 560 points wide on iPad and Mac, the full
/// width (less a margin) on iPhone.
struct GameCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(24)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
            .shadow(color: .black.opacity(0.15), radius: 24, y: 10)
            .padding(16)
    }
}

/// Centres its content vertically when it fits and scrolls when it doesn't (small or landscape iPhones).
struct CenteredScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// A row of stars (or dots), `filled` of them coloured.
struct StarRow: View {
    let count: Int
    let filled: Int
    var size: CGFloat = 16
    var symbol = "star.fill"
    var color = GameColors.hint

    var body: some View {
        HStack(spacing: size * 0.2) {
            ForEach(0..<count, id: \.self) { i in
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(i < filled ? color : Color.secondary.opacity(0.3))
            }
        }
    }
}

/// The soft background behind the game.
struct GameBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = colorScheme == .dark
            ? [Color(red: 0.06, green: 0.07, blue: 0.13), Color(red: 0.1, green: 0.08, blue: 0.19)]
            : [Color(red: 0.92, green: 0.96, blue: 1), Color(red: 0.97, green: 0.95, blue: 1)]
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

extension View {
    /// The pointer's lift effect on iPad for custom-drawn buttons (system button styles have their own).
    @ViewBuilder
    func gameHoverEffect() -> some View {
        #if os(iOS)
        hoverEffect(.lift)
        #else
        self
        #endif
    }
}
