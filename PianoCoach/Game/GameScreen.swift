import PianoCoachCore
import SwiftUI

/// The Game tab: the falling-notes game for the open piece, from the start screen through the count-in
/// and the game to the results.
///
/// A hardware keyboard plays too (Mac, or iPad with a keyboard): A W S E D F T G Y H U J K are the white and
/// black keys from C4 to C5, and on iPad the space bar starts, pauses and resumes (the Mac uses the buttons'
/// space shortcuts).
struct GameScreen: View {
    @Environment(AppModel.self) private var model
    /// Opens the piece's setup (to add sheet music).
    var onAddSheetMusic: () -> Void

    @FocusState private var hasKeyboardFocus: Bool

    var body: some View {
        let game = model.game
        ZStack {
            GameBackground()
            content(game)
        }
        .focusable(interactions: .edit)
        .focused($hasKeyboardFocus)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handle(press) }
        .onAppear { hasKeyboardFocus = true }
        .onChange(of: game.phase) { hasKeyboardFocus = true }
    }

    @ViewBuilder
    private func content(_ game: GameController) -> some View {
        if let chart = game.chart, game.phase != .noChart {
            if game.phase == .ready {
                StartPanel(game: game, chart: chart, onAddSheetMusic: onAddSheetMusic)
            } else {
                PlayArea(game: game, chart: chart)
            }
        } else {
            NoSongPanel(onAddSheetMusic: onAddSheetMusic)
        }
    }

    // MARK: Computer keyboard

    /// Computer keys laid out like a piano: A W S E D F T G Y H U J K play C4 up to C5.
    static let computerKeys: [Character: Int] = [
        "a": 60, "w": 61, "s": 62, "e": 63, "d": 64, "f": 65, "t": 66,
        "g": 67, "y": 68, "h": 69, "u": 70, "j": 71, "k": 72,
    ]

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let game = model.game
        guard game.chart != nil, press.modifiers.intersection([.command, .control, .option]).isEmpty else {
            return .ignored
        }
        if let character = press.characters.lowercased().first, let midi = Self.computerKeys[character] {
            game.tapKey(midi)
            return .handled
        }
        #if os(iOS)
        if press.key == .space {
            spaceBar(game)
            return .handled
        }
        #endif
        return .ignored
    }

    /// Start, pause or resume, like the space-bar shortcuts on the Mac.
    private func spaceBar(_ game: GameController) {
        switch game.phase {
        case .ready: game.start()
        case .countIn, .playing, .paused: game.togglePause()
        case .demo: game.stopDemo()
        case .finished: game.restart()
        case .noChart: break
        }
    }
}

// MARK: - Playing

/// The game itself: the HUD, the notes (falling or on the staff) and the keyboard, with the count-in,
/// pause and results on top. Every size comes from the space available (iPad split view, Stage Manager).
private struct PlayArea: View {
    let game: GameController
    let chart: NoteChart

    var body: some View {
        let layout = KeyboardLayout(chart: chart)
        let display = game.display
        GeometryReader { geo in
            VStack(spacing: 0) {
                if game.phase == .demo {
                    DemoBar(game: game)
                } else {
                    GameHUD(game: game, compact: geo.size.width < 520)
                }
                ZStack(alignment: .top) {
                    if display == .keys {
                        FallingNotesView(game: game, chart: chart, layout: layout)
                    } else {
                        StaffView(game: game, chart: chart)
                    }
                    // At the top, clear of the notes at the line.
                    VStack(spacing: 8) {
                        CheerBubble(game: game)
                        WaitingHint(game: game)
                    }
                    .padding(.top, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                GameKeyboard(game: game, layout: layout)
                    .frame(height: Self.keyboardHeight(for: geo.size, layout: layout, display: display))
            }
        }
        .overlay { PhaseOverlay(game: game) }
    }

    /// Big, touch-friendly keys under the falling notes (about a quarter of the height); a smaller keyboard
    /// under the staff, which needs the room.
    static func keyboardHeight(for size: CGSize, layout: KeyboardLayout, display: GameDisplay) -> CGFloat {
        let whiteKey = layout.whiteKeyWidth(forWidth: size.width)
        switch display {
        case .keys: return max(80, min(size.height * 0.24, whiteKey * 5.5, 280))
        case .notes: return max(64, min(size.height * 0.17, whiteKey * 4.5, 170))
        }
    }
}

/// The keyboard under the notes: lit by what is played, hinting at what comes next, and playable by touch.
private struct GameKeyboard: View {
    let game: GameController
    let layout: KeyboardLayout

    var body: some View {
        PianoKeyboardView(layout: layout, glows: game.keyGlows, hints: game.upcomingKeys, showLetters: game.showLetters,
                          onPress: { game.tapKey($0) })
    }
}

/// The count-in, the pause panel or the results, over the game.
private struct PhaseOverlay: View {
    let game: GameController

    var body: some View {
        ZStack {
            switch game.phase {
            case .countIn(let number):
                CountInOverlay(number: number)
                    .transition(.opacity)
            case .paused:
                PausedPanel(game: game)
                    .transition(.opacity)
            case .finished:
                if let result = game.result {
                    ResultsPanel(game: game, result: result)
                        .transition(.opacity)
                }
            default:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: game.phase)
    }
}
