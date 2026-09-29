import CoreMIDI
import Foundation

/// Note input from USB and Bluetooth MIDI keyboards: listens to every MIDI source and reports note-ons.
///
/// `onNoteOn` runs on CoreMIDI's high-priority receive thread and must hand work off quickly. The
/// CoreMIDI blocks are formed in this non-isolated class on purpose (see `AudioInputHub`).
/// Bluetooth keyboards must be paired first: on iOS with `BluetoothMIDIPairingView`, on macOS in
/// Audio MIDI Setup. Once connected they appear as ordinary sources.
final class MIDIInputManager: @unchecked Sendable {
    struct MIDIError: LocalizedError {
        let operation: String
        let status: OSStatus

        var errorDescription: String? {
            switch status {
            case kMIDIServerStartErr: return "The MIDI system couldn't start (error \(status))."
            case kMIDINotPermitted: return "MIDI isn't allowed for this app (error \(status))."
            default: return "\(operation) failed (error \(status))."
            }
        }
    }

    // `handlerLock` is never held while calling CoreMIDI, so the receive thread can't deadlock with start/stop.
    private let handlerLock = NSLock()
    private var noteHandler: (@Sendable (_ note: Int, _ velocity: Int, _ time: Double) -> Void)?
    private var names: [String] = []

    // Guarded by `stateLock`.
    private let stateLock = NSLock()
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: [MIDIEndpointRef] = []
    private var listening = false

    private let refreshQueue = DispatchQueue(label: "PianoCoach.MIDIInputManager")
    private var refreshPending = false   // accessed only on `refreshQueue`

    /// Called for each note-on with the MIDI note number, velocity 1...127 and `MonotonicClock` time.
    var onNoteOn: (@Sendable (_ note: Int, _ velocity: Int, _ time: Double) -> Void)? {
        get { handlerLock.withLock { noteHandler } }
        set { handlerLock.withLock { noteHandler = newValue } }
    }

    /// Names of the MIDI sources currently available (e.g. "Digital Piano").
    private(set) var sourceNames: [String] {
        get { handlerLock.withLock { names } }
        set { handlerLock.withLock { names = newValue } }
    }

    init() {}

    deinit {
        if port != 0 { MIDIPortDispose(port) }
        // The client is kept: disposing an app's last client can stop the MIDI server for the app.
    }

    /// Connects every MIDI source, now and whenever a keyboard is plugged in or paired later.
    /// Safe to call repeatedly.
    func start() throws {
        try stateLock.withLock {
            try createPortLocked()
            listening = true
            reconnectSourcesLocked()
        }
    }

    /// Disconnects all sources (the MIDI client stays, so starting again is cheap).
    func stop() {
        stateLock.withLock {
            listening = false
            for source in connected { MIDIPortDisconnectSource(port, source) }
            connected.removeAll()
        }
    }

    // MARK: - Setup

    private func createPortLocked() throws {
        if client == 0 {
            var newClient = MIDIClientRef()
            let status = MIDIClientCreateWithBlock("Piano Coach" as CFString, &newClient) { @Sendable [weak self] message in
                switch message.pointee.messageID {
                case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved:
                    self?.scheduleRefresh()
                default:
                    break
                }
            }
            guard status == noErr else { throw MIDIError(operation: "Creating the MIDI client", status: status) }
            client = newClient
        }
        if port == 0 {
            var newPort = MIDIPortRef()
            let status = MIDIInputPortCreateWithProtocol(client, "Piano Coach Input" as CFString, ._1_0, &newPort) { @Sendable [weak self] eventList, _ in
                self?.receive(eventList)
            }
            guard status == noErr else { throw MIDIError(operation: "Opening the MIDI input", status: status) }
            port = newPort
        }
    }

    /// Runs on an arbitrary CoreMIDI thread; a plug-in produces several notifications, handled once.
    private func scheduleRefresh() {
        refreshQueue.async { [weak self] in
            guard let self, !self.refreshPending else { return }
            self.refreshPending = true
            self.refreshQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                self.refreshPending = false
                self.stateLock.withLock { self.reconnectSourcesLocked() }
            }
        }
    }

    /// Lists the sources and, while listening, connects each exactly once. Connections are made
    /// afresh because a keyboard that was unplugged and plugged back in keeps its endpoint.
    private func reconnectSourcesLocked() {
        var sources: [MIDIEndpointRef] = []
        var available: [String] = []
        let count = MIDIGetNumberOfSources()
        for index in 0..<count {
            let source = MIDIGetSource(index)
            guard source != 0 else { continue }
            sources.append(source)
            available.append(Self.displayName(of: source))
        }
        if port != 0 {
            for source in connected { MIDIPortDisconnectSource(port, source) }
            connected.removeAll()
            if listening {
                for source in sources {
                    if MIDIPortConnectSource(port, source, nil) == noErr { connected.append(source) }
                }
            }
        }
        sourceNames = available
    }

    private static func displayName(of endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr,
              let value = name?.takeRetainedValue() as String?, !value.isEmpty else { return "MIDI device" }
        return value
    }

    // MARK: - Receiving

    /// Runs on CoreMIDI's receive thread.
    private func receive(_ eventList: UnsafePointer<MIDIEventList>) {
        guard let handler = onNoteOn else { return }
        let now = MonotonicClock.now()
        for packet in eventList.unsafeSequence() {
            let time = Self.clockTime(of: packet.pointee.timeStamp, now: now)
            Self.forEachNoteOn(in: packet.words()) { note, velocity in
                handler(note, velocity, time)
            }
        }
    }

    /// A MIDI timestamp is host time, 0 meaning "now". Implausible ones (from the future, or over a
    /// second old) are replaced by the arrival time.
    static func clockTime(of timeStamp: MIDITimeStamp, now: Double) -> Double {
        guard timeStamp != 0 else { return now }
        let time = MonotonicClock.seconds(hostTime: timeStamp)
        return time > now || now - time > 1 ? now : time
    }

    /// Calls `body` for each note-on in a stream of Universal MIDI Packet words: MIDI 1.0 channel
    /// voice messages (where a note-on with velocity 0 is a note-off) and, should a source deliver
    /// them, MIDI 2.0 ones. Every other message is skipped by its size.
    static func forEachNoteOn<Words: Sequence>(in words: Words, _ body: (_ note: Int, _ velocity: Int) -> Void)
        where Words.Element == UInt32 {
        var iterator = words.makeIterator()
        while let word = iterator.next() {
            let type = word >> 28
            let isNoteOn = (word >> 20) & 0xF == 0x9
            let note = Int((word >> 8) & 0x7F)
            switch type {
            case 0x2:
                let velocity = Int(word & 0x7F)
                if isNoteOn && velocity > 0 { body(note, velocity) }
            case 0x4:
                // Velocity is the top 16 bits of the second word; 0 is still a note-on in MIDI 2.0.
                guard let second = iterator.next() else { return }
                if isNoteOn { body(note, max(1, Int(second >> 25))) }
            default:
                for _ in 1..<wordCount(ofMessageType: type) {
                    guard iterator.next() != nil else { return }
                }
            }
        }
    }

    /// Size in 32-bit words of a Universal MIDI Packet, from its message type (the top 4 bits).
    private static func wordCount(ofMessageType type: UInt32) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }
}
