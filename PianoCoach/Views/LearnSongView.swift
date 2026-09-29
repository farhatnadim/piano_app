import PianoCoachCore
import SwiftUI

/// Turns a song's video into a game: the video plays once while the app writes down its notes. Also
/// offers an audio file or exact notes (MIDI, MusicXML) instead.
///
/// Nothing is ever drawn on top of the YouTube player (YouTube's rules).
struct LearnSongView: View {
    @Environment(AppModel.self) private var model
    @Binding var importing: NotesImport?

    var body: some View {
        let learner = model.learner
        ZStack {
            GameBackground()
            ScrollView {
                VStack(spacing: 20) {
                    WebViewContainer(webView: model.player.webView)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: 720, minHeight: 200)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    playerNotices
                    GameCard {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("Let's turn this song into a game")
                                .font(.title2.weight(.bold))
                            steps
                            status(learner)
                        }
                    }
                    otherWays
                    if model.isRelearning {
                        Button { model.closeLearnScreen() } label: {
                            Label("Back to the game", systemImage: "gamecontroller.fill")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .disabled(learner.isWorking)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepRow(number: 1, text: "The video plays once while Piano Coach listens and writes down every note.")
            StepRow(number: 2, text: "Then the notes fall onto the piano keys — and the song plays as slowly or as quickly as you like.")
        }
    }

    @ViewBuilder
    private func status(_ learner: SongLearner) -> some View {
        switch learner.phase {
        case .idle, .failed:
            if case .failed(let message) = learner.phase {
                NoticeBanner(message, style: .warning)
            }
            Button { model.learnFromVideo() } label: {
                Label("Listen and write the notes", systemImage: "ear")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(model.player.errorMessage != nil)
            Text(captureHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .starting:
            HStack(spacing: 12) {
                ProgressView()
                Text("Getting ready to listen…")
                    .font(.headline)
            }
        case .listening:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "ear.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .symbolEffect(.pulse)
                    Text("Listening… \(timeText(learner.heardSeconds))")
                        .font(.headline)
                        .monospacedDigit()
                    Spacer()
                    LevelMeter(level: learner.level)
                        .frame(width: 90)
                }
                if learner.usesMicrophone {
                    NoticeBanner("I'm listening through the microphone. Keep the room quiet and the sound up.",
                                 systemImage: "mic.fill")
                }
                Text("Let the video play to the end. You can also stop early and use what I heard so far.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { learner.finishListening() } label: {
                        Label("Write the notes now", systemImage: "checkmark")
                            .frame(minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    Button("Cancel", role: .cancel) { learner.cancel() }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
            }
        case .transcribing(let fraction):
            VStack(alignment: .leading, spacing: 10) {
                Text("Writing down the notes…")
                    .font(.headline)
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                Button("Cancel", role: .cancel) { learner.cancel() }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
    }

    private var captureHint: String {
        #if os(iOS)
        return "Your iPad will ask to record the screen: that's how Piano Coach hears the video. Only the notes are kept."
        #else
        return "Your Mac will ask to let Piano Coach record the screen and sound: that's how it hears the video. Only the notes are kept. Other sounds playing at the same time are heard too."
        #endif
    }

    @ViewBuilder
    private var playerNotices: some View {
        let player = model.player
        if player.autoplayBlocked {
            NoticeBanner("Tap the video once to let it play.", systemImage: "hand.tap.fill")
                .frame(maxWidth: 720)
        }
        if let error = player.errorMessage {
            NoticeBanner("\(error) You can use an audio file of the song instead.", style: .error)
                .frame(maxWidth: 720)
        }
    }

    private var otherWays: some View {
        VStack(spacing: 10) {
            Text("Other ways")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { otherWayButtons }
                VStack(spacing: 10) { otherWayButtons }
            }
        }
        .disabled(model.learner.isWorking)
    }

    @ViewBuilder
    private var otherWayButtons: some View {
        Button { importing = .audio } label: {
            Label("Use an audio file", systemImage: "waveform")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        Button { importing = .notes } label: {
            Label("Use a MIDI or MusicXML file", systemImage: "doc.badge.plus")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }
}

/// A numbered step of the explanation.
private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background { Circle().fill(Color.accentColor) }
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
