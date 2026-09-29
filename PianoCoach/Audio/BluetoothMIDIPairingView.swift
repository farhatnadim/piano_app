#if os(iOS)
import SwiftUI
#if canImport(CoreAudioKit)
import CoreAudioKit
#endif

/// Apple's Bluetooth MIDI pairing screen, for a parent to connect a Bluetooth keyboard. Present it in a
/// sheet. A paired keyboard becomes a MIDI source, which `MIDIInputManager` connects by itself.
/// Needs `NSBluetoothAlwaysUsageDescription` in Info.plist.
struct BluetoothMIDIPairingView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            central
                .navigationTitle("Bluetooth Keyboard")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder private var central: some View {
        #if canImport(CoreAudioKit)
        BluetoothMIDICentral()
        #else
        Text("Bluetooth keyboards can't be paired on this device.")
            .foregroundStyle(.secondary)
        #endif
    }
}

#if canImport(CoreAudioKit)
private struct BluetoothMIDICentral: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CABTMIDICentralViewController {
        CABTMIDICentralViewController()
    }

    func updateUIViewController(_ controller: CABTMIDICentralViewController, context: Context) {}
}
#endif
#endif
