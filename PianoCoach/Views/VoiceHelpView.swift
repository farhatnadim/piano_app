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
            Phrase(words: "Play", detail: "Start the game, or carry on. “Go” and “keep going” work too.", symbol: "play.fill"),
            Phrase(words: "Stop", detail: "Stop right where you are. Or say “pause” or “wait”.", symbol: "pause.fill"),
            Phrase(words: "Again", detail: "Start the song over. “From the top” works too.", symbol: "arrow.counterclockwise"),
            Phrase(words: "Listen", detail: "The piano plays the song while the keys light up.", symbol: "ear"),
        ]),
        PhraseGroup(title: "Speed", phrases: [
            Phrase(words: "Slower", detail: "A little slower. Or “reduce speed”, “too fast”.", symbol: "tortoise.fill"),
            Phrase(words: "Faster", detail: "A little faster. Or “increase speed”, “too slow”.", symbol: "hare.fill"),
            Phrase(words: "Normal speed", detail: "The song's real speed.", symbol: "speedometer"),
            Phrase(words: "Half speed", detail: "Or say a number, like “speed 75”.", symbol: "gauge.with.dots.needle.33percent"),
        ]),
        PhraseGroup(title: "What you see", phrases: [
            Phrase(words: "Show the notes", detail: "The notes on a music staff.", symbol: "music.note.list"),
            Phrase(words: "Show the keys", detail: "Notes falling onto the piano keys.", symbol: "pianokeys"),
            Phrase(words: "Right hand", detail: "Practise one hand. “Left hand” and “both hands” work too.", symbol: "hand.raised.fill"),
        ]),
        PhraseGroup(title: "More", phrases: [
            Phrase(words: "Sound off", detail: "Mute the app's piano. “Sound on” brings it back.", symbol: "speaker.slash.fill"),
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
            return "Start with “Coach”, like “Coach, slower” or “Coach, play”."
        }
        return "Just say it out loud. You can also start with “Coach”, like “Coach, slower”."
    }
}
