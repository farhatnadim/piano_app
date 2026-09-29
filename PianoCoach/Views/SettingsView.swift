import SwiftUI

/// The parent's settings. A sheet on iPhone/iPad, the Settings window on the Mac.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            form
                .navigationTitle("Settings")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                #endif
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 520, idealHeight: 680)
        #endif
    }

    private var form: some View {
        let settings = model.settings
        return Form {
            Section {
                Picker("Listen with", selection: binding(\.noteSource)) {
                    ForEach(NoteSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                if settings.noteSource == .microphone {
                    SettingSlider(title: "Sensitivity", value: binding(\.sensitivity), range: 0...1, step: 0.05,
                                  valueText: sensitivityText(settings.sensitivity),
                                  minimumLabel: "Clear notes", maximumLabel: "Soft notes")
                }
            } header: {
                Text("Hearing the piano")
            } footer: {
                Text("A MIDI keyboard (USB or Bluetooth) is the most accurate: the coach knows exactly which keys are pressed. The microphone works with any piano. Raise the sensitivity if soft playing is missed; lower it if the coach reacts to talking or noise.")
            }

            Section {
                SettingSlider(title: "Pause after quiet", value: binding(\.silenceTimeout), range: 1...6, step: 0.5,
                              valueText: String(format: "%.1f s", settings.silenceTimeout))
                SettingSlider(title: "Video may get ahead by", value: binding(\.maxLead), range: 0.3...3, step: 0.1,
                              valueText: String(format: "%.1f s", settings.maxLead))
                Toggle("Let the video go faster than normal", isOn: binding(\.allowFasterThanNormal))
            } header: {
                Text("Waiting and following")
            } footer: {
                Text("How long the coach waits in silence before pausing the video, and how far the video may run ahead of your child before it waits for them.")
            }

            Section {
                Toggle("Mute the video while listening", isOn: binding(\.muteVideoWhileListening))
                Toggle("Echo cancellation (experimental)", isOn: binding(\.echoCancellation))
            } header: {
                Text("Microphone")
            } footer: {
                Text("With the video's sound on, the microphone also hears the piano in the video and may think your child is playing. Headphones avoid this. Echo cancellation tries to remove the video's sound but can also make piano notes harder to hear.")
            }

            Section {
                Toggle("Listen for voice commands", isOn: binding(\.voiceCommandsEnabled))
                Toggle("Only after “Coach”", isOn: binding(\.requireWakeWord))
                    .disabled(!settings.voiceCommandsEnabled)
                NavigationLink {
                    VoiceHelpView()
                } label: {
                    Label("Things you can say", systemImage: "text.bubble")
                }
            } header: {
                Text("Voice commands")
            } footer: {
                Text("Your child can say “slower”, “again” or “measure twelve”. With “Only after Coach” on, the app reacts only to “Coach, slower” and so on — useful if it reacts to normal talking.")
            }

            Section("Sheet music") {
                Picker("Show the music", selection: binding(\.sheetLayout)) {
                    ForEach(SheetLayout.allCases) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
            }

            Section {
                SettingSlider(title: "Speaker delay when learning", value: binding(\.learnLatency), range: 0...0.3,
                              step: 0.01, valueText: "\(Int((settings.learnLatency * 1000).rounded())) ms")
                Button("Reset coach settings", role: .destructive) { confirmReset = true }
            } header: {
                Text("Advanced")
            } footer: {
                Text("The speaker delay is the time between the video playing a note and the microphone hearing it. Only change it if “Follow me” is consistently early or late after the coach learned a song.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset the coach settings?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                model.settings.resetCoachDefaults()
                model.applySettings()
            }
        } message: {
            Text("Sensitivity, waiting, microphone and learning settings go back to their defaults.")
        }
    }

    /// A binding to a setting that pushes every change to the coach.
    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        let appModel = model
        let settings = appModel.settings
        return Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                settings[keyPath: keyPath] = newValue
                appModel.applySettings()
            }
        )
    }

    private func sensitivityText(_ value: Double) -> String {
        switch value {
        case ..<0.3: return "Low"
        case ..<0.7: return "Medium"
        default: return "High"
        }
    }
}

/// A titled slider with its current value on the right.
private struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String
    var minimumLabel: String?
    var maximumLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step) {
                Text(title)
            } minimumValueLabel: {
                Text(minimumLabel ?? "").font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(maximumLabel ?? "").font(.caption).foregroundStyle(.secondary)
            }
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}
