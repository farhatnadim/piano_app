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

    var body: some Scene {
        #if os(macOS)
        // A single window: the YouTube player and the audio engine exist once, so a second window can't share them.
        Window("Piano Coach", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 540)
                // Closing the window or quitting stops the sound and the microphone.
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
    /// Stops the game, the learning, the sound and the microphone when the app leaves the screen. The
    /// song stays open.
    private func pauseForBackground() {
        model.game.hold()
        model.game.stopDemo()
        model.learner.cancel()
        model.input.stopListening()
        model.player.pause()
        model.voice.stop()
        model.sound.stop()
        model.audio.stop()
    }

    /// Restarts voice commands (the game stays paused until the child carries on).
    private func resumeFromBackground() {
        model.applySettings()
    }
    #endif
}
