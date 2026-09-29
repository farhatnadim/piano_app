#if os(iOS)
import CoreAudioKit
import SwiftUI

/// Apple's screen for finding and connecting Bluetooth MIDI keyboards. Push it inside a
/// `NavigationStack` (or present it in one). A connected keyboard shows up as a MIDI source, which
/// `MIDIInputManager` picks up by itself. Needs `NSBluetoothAlwaysUsageDescription` in Info.plist.
struct BluetoothMIDIPairingView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CABTMIDICentralViewController {
        CABTMIDICentralViewController()
    }

    func updateUIViewController(_ uiViewController: CABTMIDICentralViewController, context: Context) {}
}
#endif
