import SwiftUI

/// Things the child can say to the app, grouped by what they do.
struct VoiceHelpView: View {
    @Environment(AppModel.self) private var model

    private struct Phrase: Identifiable {
        let words: String
        let detail: String
        let symbol: String
        var id: String { words }
    }

    private struct PhraseGroup: Identifiable {
        let title: String
        let phrases: [Phrase]
        var id: String { title }
    }

    private static let groups: [PhraseGroup] = [
        PhraseGroup(title: "Playing", phrases: [
            Phrase(words: "Play", detail: "Start the video. “Keep going” works too.", symbol: "play.fill"),
            Phrase(words: "Pause", detail: "Stop the video. Or say “stop” or “wait”.", symbol: "pause.fill"),
            Phrase(words: "Again", detail: "Play that part one more time.", symbol: "arrow.counterclockwise"),
            Phrase(words: "From the top", detail: "Start the piece from the beginning.", symbol: "backward.end.fill"),
        ]),
        PhraseGroup(title: "Speed", phrases: [
            Phrase(words: "Slower", detail: "Make the video a bit slower.", symbol: "tortoise.fill"),
            Phrase(words: "Faster", detail: "Make the video a bit faster.", symbol: "hare.fill"),
            Phrase(words: "Normal speed", detail: "Back to the real speed.", symbol: "speedometer"),
            Phrase(words: "Half speed", detail: "Or say a number, like “speed 75”.", symbol: "gauge.with.dots.needle.33percent"),
        ]),
        PhraseGroup(title: "Music", phrases: [
            Phrase(words: "Show the music", detail: "Show the sheet music.", symbol: "music.note.list"),
            Phrase(words: "Hide the music", detail: "Hide the sheet music.", symbol: "eye.slash"),
        ]),
        PhraseGroup(title: "Moving around", phrases: [
            Phrase(words: "Go back", detail: "Jump back a little.", symbol: "gobackward"),
            Phrase(words: "Skip ahead", detail: "Jump forward a little.", symbol: "goforward"),
            Phrase(words: "Measure twelve", detail: "Jump to a measure (needs sheet music). “Bar 12” works too.", symbol: "number"),
            Phrase(words: "Loop this", detail: "Keep repeating this part.", symbol: "repeat"),
            Phrase(words: "Stop looping", detail: "Carry on without repeating.", symbol: "arrow.right"),
        ]),
        PhraseGroup(title: "Coach", phrases: [
            Phrase(words: "Wait for me", detail: "The video waits when you stop playing.", symbol: "hourglass"),
            Phrase(words: "Follow me", detail: "The video follows your speed.", symbol: "figure.walk"),
            Phrase(words: "Coach off", detail: "The video plays normally.", symbol: "power"),
            Phrase(words: "Sound off", detail: "Mute the video. “Sound on” brings it back.", symbol: "speaker.slash.fill"),
            Phrase(words: "What can I say?", detail: "Shows this list.", symbol: "questionmark.circle"),
        ]),
    ]

    var body: some View {
        List {
            Section {
                Label {
                    Text(wakeWordNote)
                } icon: {
                    Image(systemName: model.settings.voiceCommandsEnabled ? "mic.fill" : "mic.slash.fill")
                        .foregroundStyle(.tint)
                }
            }
            ForEach(Self.groups) { group in
                Section(group.title) {
                    ForEach(group.phrases) { phrase in
                        HStack(spacing: 14) {
                            Image(systemName: phrase.symbol)
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("“\(phrase.words)”")
                                    .font(.headline)
                                Text(phrase.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .navigationTitle("Things you can say")
    }

    private var wakeWordNote: String {
        if !model.settings.voiceCommandsEnabled {
            return "Voice commands are turned off. A grown-up can turn them on in Settings."
        }
        if model.settings.requireWakeWord {
            return "Start with “Coach”, like “Coach, slower” or “Coach, measure twelve”."
        }
        return "Just say it out loud. You can also start with “Coach”, like “Coach, slower”."
    }
}
