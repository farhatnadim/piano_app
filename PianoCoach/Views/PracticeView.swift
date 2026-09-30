import PianoCoachCore
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// The screen for the open song: the game, or — until the app has learned the song's notes — the learn
/// screen with the video.
struct PracticeView: View {
    @Environment(AppModel.self) private var model
    @State private var importing: NotesImport?
    @State private var importError: String?

    var body: some View {
        Group {
            if model.needsLearning {
                LearnSongView(importing: $importing)
            } else {
                GameScreen { model.showLearnScreen() }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PracticeBanners(importError: $importError)
        }
        .overlay(alignment: .bottom) {
            ToastOverlay()
        }
        .navigationTitle(model.openPiece?.title ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.voice.isRunning {
                    VoiceIndicator()
                }
                SongMenu(importing: $importing)
            }
        }
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: importing?.contentTypes ?? []) { result in
            let kind = importing
            importing = nil
            guard case .success(let url) = result, let kind else { return }
            switch kind {
            case .audio:
                model.learnFromAudioFile(url)
            case .notes:
                do {
                    try model.importNotes(from: url)
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
    }
}

/// A file the parent can give instead of (or besides) the video.
enum NotesImport: Identifiable {
    /// A recording of the song, to learn the notes from.
    case audio
    /// Exact notes: MIDI or MusicXML.
    case notes

    var id: Self { self }

    var contentTypes: [UTType] {
        switch self {
        case .audio:
            return [.audio]
        case .notes:
            let musicXML = ["musicxml", "mxl"].compactMap { UTType(filenameExtension: $0) }
            return [.midi, .xml] + musicXML
        }
    }
}

/// The toolbar menu: learn again, use a file instead, trim, share the notes, voice commands.
private struct SongMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var importing: NotesImport?

    var body: some View {
        Menu {
            if !model.needsLearning {
                Button { model.showLearnScreen() } label: {
                    Label("Learn it again from the video", systemImage: "ear")
                }
            }
            Button { importing = .audio } label: {
                Label("Learn from an audio file…", systemImage: "waveform")
            }
            Button { importing = .notes } label: {
                Label("Use a MIDI or MusicXML file…", systemImage: "doc.badge.plus")
            }
            if !model.needsLearning, model.game.fullChart != nil {
                Button { model.showTrimScreen = true } label: {
                    Label("Trim the start or end…", systemImage: "scissors")
                }
            }
            if let url = model.notesFileURL, !model.needsLearning {
                ShareLink(item: url) {
                    Label("Share the notes", systemImage: "square.and.arrow.up")
                }
            }
            Divider()
            Button { model.showVoiceHelp = true } label: {
                Label("Things you can say", systemImage: "text.bubble")
            }
        } label: {
            Label("Song", systemImage: "ellipsis.circle")
        }
        .help("Learn the song again, use a file, trim it, or share its notes")
    }
}

/// A microphone that bounces whenever speech is heard, with the last words as a tooltip.
private struct VoiceIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.showVoiceHelp = true } label: {
            Image(systemName: "mic.fill")
                .symbolEffect(.bounce, value: model.voice.lastTranscript)
        }
        .help(Text(model.voice.lastTranscript.isEmpty
                   ? (model.settings.requireWakeWord ? "Listening for “Coach, …”" : "Listening for voice commands")
                   : "Heard: “\(model.voice.lastTranscript)”"))
        .accessibilityLabel("Voice commands are on. Show what you can say.")
    }
}

// MARK: - Banners and toast

/// Problems the parent should know about, above the game or the learn screen.
private struct PracticeBanners: View {
    @Environment(AppModel.self) private var model
    @Binding var importError: String?

    var body: some View {
        VStack(spacing: 8) {
            if let error = importError {
                NoticeBanner(error, style: .warning, onDismiss: { importError = nil })
            }
            if let error = model.notesError {
                NoticeBanner(error, style: .error)
            }
            if let error = nonEmpty(model.voice.errorMessage) {
                NoticeBanner(error, style: .warning, systemImage: "mic.slash", accessory: {
                    if error == AudioHub.HubError.permissionDenied.localizedDescription,
                       let url = Self.privacySettingsURL {
                        Link("Open Settings", destination: url)
                    }
                })
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, importError != nil || model.notesError != nil || nonEmpty(model.voice.errorMessage) != nil ? 8 : 0)
        .frame(maxWidth: 720)
    }

    static var privacySettingsURL: URL? {
        #if os(iOS)
        return URL(string: UIApplication.openSettingsURLString)
        #else
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #endif
    }
}

/// The voice-command confirmation, near the bottom of the screen.
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
