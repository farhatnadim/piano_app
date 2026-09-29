import Combine
import PianoCoachCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct PianoCoachApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    /// The coach mode to bring back when the app returns to the screen.
    @State private var modeBeforeBackground: CoachMode?
    #endif

    var body: some Scene {
        #if os(macOS)
        // A single window: the YouTube player and the coach exist once, so a second window can't share them.
        Window("Piano Coach", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 540)
                // Closing the window or quitting saves where the video was and stops the microphone.
                .onDisappear { model.closePiece() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.closePiece()
                }
        }
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView()
                .environment(model)
        }
        #else
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: pauseForBackground()
            case .active: resumeFromBackground()
            default: break
            }
        }
        #endif
    }

    #if os(iOS)
    /// Stops the video, the coach and the microphone when the app leaves the screen, and saves where the
    /// video was. The piece stays open.
    private func pauseForBackground() {
        let coach = model.coach
        coach.cancelLearning()
        if coach.mode != .off { modeBeforeBackground = coach.mode }
        coach.setMode(.off)
        coach.stopListening()
        model.player.pause()
        model.voice.stop()
        model.audio.stop()
        if var piece = model.openPiece {
            piece.resumeTime = model.player.currentTime
            piece.loop = coach.loop
            model.update(piece)
        }
    }

    /// Restarts voice commands and the coach (paused; it waits for the child as usual).
    private func resumeFromBackground() {
        model.applySettings()
        if let mode = modeBeforeBackground, model.openPiece != nil {
            model.coach.setMode(mode)
        }
        modeBeforeBackground = nil
    }
    #endif
}
