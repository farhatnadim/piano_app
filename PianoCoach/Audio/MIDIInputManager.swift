import CoreMIDI
import Foundation

/// Note-ons from USB or Bluetooth MIDI keyboards (CoreMIDI, iOS and macOS).
///
/// Listens to every MIDI source and follows the MIDI setup, so a keyboard plugged in (or paired) while
/// listening is picked up by itself. `onNoteOn` is called on CoreMIDI's receive thread.
final class MIDIInputManager: @unchecked Sendable {
    struct MIDIError: LocalizedError {
        let action: String
        let status: OSStatus

        var errorDescription: String? {
            if status == kMIDINotPermitted || status == kMIDIServerStartErr {
                return "MIDI isn't available right now (error \(status))."
            }
            return "Couldn't \(action) (MIDI error \(status))."
        }
    }

    /// Words in a Universal MIDI Packet message, by message type (the top four bits of its first word).
    private static let umpWordCounts = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]
    /// MIDI channel 10 (index 9) carries drums, e.g. a keyboard's accompaniment rhythm.
    private static let drumChannel: UInt32 = 9
    /// The always-present "Network Session" source isn't a keyboard.
    private static let networkDriver = "com.apple.AppleMIDIRTPDriver"

    /// Guards the handler and names; held only briefly.
    private let lock = NSLock()
    private var noteHandler: (@Sendable (_ note: Int, _ velocity: Int, _ time: Double) -> Void)?
    private var noteOffHandler: (@Sendable (_ note: Int, _ time: Double) -> Void)?
    private var names: [String] = []

    /// Serialises setup; never taken on the receive thread.
    private let setupLock = NSLock()
    // Guarded by `setupLock`.
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var active = false
    /// Connected sources, and whether each was offline when last seen.
    private var connected: [MIDIEndpointRef: Bool] = [:]

    private let refreshQueue = DispatchQueue(label: "PianoCoach.MIDIInputManager.refresh")
    private var refreshPending = false  // guarded by `lock`

    /// Called for every note-on (velocity 1...127) with its time in `MonotonicClock` seconds.
    var onNoteOn: (@Sendable (_ note: Int, _ velocity: Int, _ time: Double) -> Void)? {
        get { lock.withLock { noteHandler } }
        set { lock.withLock { noteHandler = newValue } }
    }

    /// Called for every note-off (including note-on with velocity 0) with its time in `MonotonicClock` seconds.
    var onNoteOff: (@Sendable (_ note: Int, _ time: Double) -> Void)? {
        get { lock.withLock { noteOffHandler } }
        set { lock.withLock { noteOffHandler = newValue } }
    }

    /// Names of the connected keyboards (online sources other than the network session).
    var sourceNames: [String] { lock.withLock { names } }

    init() {}

    /// Connects every MIDI source. Idempotent; call it on the main thread, whose run loop CoreMIDI
    /// uses to report setup changes (a keyboard plugged in, paired or switched off).
    func start() throws {
        try setupLock.withLock {
            if client == 0 {
                var newClient = MIDIClientRef()
                let status = MIDIClientCreateWithBlock("Piano Coach" as CFString, &newClient) { @Sendable [weak self] notification in
                    switch notification.pointee.messageID {
                    case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged:
                        self?.scheduleRefresh()
                    default:
                        break
                    }
                }
                guard status == noErr else { throw MIDIError(action: "start MIDI", status: status) }
                client = newClient
            }
            if port == 0 {
                var newPort = MIDIPortRef()
                let status = MIDIInputPortCreateWithProtocol(client, "Piano Coach Input" as CFString, ._1_0, &newPort) { @Sendable [weak self] eventList, _ in
                    self?.receive(eventList)
                }
                guard status == noErr else { throw MIDIError(action: "open a MIDI input", status: status) }
                port = newPort
            }
            active = true
            connectSourcesLocked()
        }
    }

    /// Disconnects all sources. The client and port stay for the next `start()`.
    func stop() {
        setupLock.withLock {
            active = false
            for source in connected.keys {
                MIDIPortDisconnectSource(port, source)
            }
            connected.removeAll()
        }
    }

    // MARK: - Sources

    /// Coalesces the burst of notifications one change produces. Setup work never runs inside the
    /// notification itself, which CoreMIDI may deliver while `start()` holds `setupLock`.
    private func scheduleRefresh() {
        let alreadyPending = lock.withLock { () -> Bool in
            defer { refreshPending = true }
            return refreshPending
        }
        guard !alreadyPending else { return }
        refreshQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.refreshPending = false }
            self.setupLock.withLock {
                if self.active { self.connectSourcesLocked() }
            }
        }
    }

    private func connectSourcesLocked() {
        var seen: [MIDIEndpointRef: Bool] = [:]
        var keyboards: [String] = []
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard source != 0 else { continue }
            let offline = Self.integerProperty(kMIDIPropertyOffline, of: source) == 1
            if let wasOffline = connected[source], !(wasOffline && !offline) {
                seen[source] = offline
            } else {
                // New, or back online (reconnect to be sure the connection is live).
                if connected[source] != nil { MIDIPortDisconnectSource(port, source) }
                if MIDIPortConnectSource(port, source, nil) == noErr { seen[source] = offline }
            }
            if !offline && Self.stringProperty(kMIDIPropertyDriverOwner, of: source) != Self.networkDriver {
                keyboards.append(Self.stringProperty(kMIDIPropertyDisplayName, of: source)
                                 ?? Self.stringProperty(kMIDIPropertyName, of: source)
                                 ?? "MIDI keyboard")
            }
        }
        for source in connected.keys where seen[source] == nil {
            MIDIPortDisconnectSource(port, source)
        }
        connected = seen
        lock.withLock { names = keyboards }
    }

    private static func stringProperty(_ property: CFString, of object: MIDIObjectRef) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func integerProperty(_ property: CFString, of object: MIDIObjectRef) -> Int32? {
        var value: Int32 = 0
        guard MIDIObjectGetIntegerProperty(object, property, &value) == noErr else { return nil }
        return value
    }

    // MARK: - Receiving (CoreMIDI's receive thread)

    private func receive(_ eventList: UnsafePointer<MIDIEventList>) {
        let (onHandler, offHandler) = lock.withLock { (noteHandler, noteOffHandler) }
        guard onHandler != nil || offHandler != nil else { return }
        let now = MonotonicClock.now()
        for packet in eventList.unsafeSequence() {
            // A timestamp of 0 means "now"; ignore implausible ones from misbehaving drivers.
            let stamp = packet.pointee.timeStamp
            var time = stamp == 0 ? now : MonotonicClock.seconds(forHostTime: stamp)
            if abs(time - now) > 1 { time = now }

            let words = packet.words()
            var index = words.startIndex
            while index < words.endIndex {
                let word = words[index]
                let type = Int(word >> 28)
                let size = Self.umpWordCounts[type]
                let status = (word >> 16) & 0xF0
                let channel = (word >> 16) & 0x0F
                if (status == 0x90 || status == 0x80) && channel != Self.drumChannel {
                    let note = Int((word >> 8) & 0x7F)
                    if type == 0x2 {
                        // MIDI 1.0 channel voice: a note-on with velocity 0 is a note-off.
                        let velocity = Int(word & 0x7F)
                        if status == 0x90 && velocity > 0 { onHandler?(note, velocity, time) } else { offHandler?(note, time) }
                    } else if type == 0x4 && index + 1 < words.endIndex {
                        // MIDI 2.0 channel voice (should the system deliver it anyway): 16-bit velocity.
                        if status == 0x90 {
                            onHandler?(note, max(1, Int(words[index + 1] >> 25)), time)
                        } else {
                            offHandler?(note, time)
                        }
                    }
                }
                index += size
            }
        }
    }
}
