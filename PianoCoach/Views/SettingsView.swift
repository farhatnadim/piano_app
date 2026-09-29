import SwiftUI

/// The parent's settings. A sheet on iPhone/iPad, the Settings window on the Mac.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false
    #if os(iOS)
    @State private var showBluetoothPairing = false
    #endif

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
                } else {
                    #if os(iOS)
                    Button { showBluetoothPairing = true } label: {
                        Label("Connect a Bluetooth keyboard…", systemImage: "dot.radiowaves.left.and.right")
                    }
                    #else
                    Text("USB keyboards work right away. Pair Bluetooth keyboards in the Audio MIDI Setup app (MIDI Studio, then Bluetooth).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    #endif
                }
            } header: {
                Text("Hearing the piano")
            } footer: {
                Text("A MIDI keyboard (USB or Bluetooth) is the most accurate: the game knows exactly which keys are pressed. The microphone works with any piano. Raise the sensitivity if soft playing is missed; lower it if the game reacts to talking or noise.")
            }

            Section {
                Toggle("Echo cancellation", isOn: binding(\.echoCancellation))
            } header: {
                Text("Microphone")
            } footer: {
                Text("Removes the app's own piano from what the microphone hears, so the game only hears your child — useful when the app plays along. It can make the piano sound a little quieter.")
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
                Text("Your child can say “play”, “stop”, “slower” or “faster”. With “Only after Coach” on, the app waits for “Coach” first (“Coach, slower”) — useful if it reacts to normal talking.")
            }

            Section {
                Button("Reset listening settings", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Piano sound: Fluid R3 grand piano by Frank Wen (CC BY 3.0). Notes are written down with Spotify's Basic Pitch (Apache 2.0).")
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .sheet(isPresented: $showBluetoothPairing) {
            BluetoothMIDIPairingView()
        }
        #endif
        .confirmationDialog("Reset the listening settings?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                model.settings.resetListeningDefaults()
                model.applySettings()
            }
        } message: {
            Text("Sensitivity and echo cancellation go back to their defaults.")
        }
    }

    /// A binding to a setting that pushes every change to the note input and voice commands.
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
