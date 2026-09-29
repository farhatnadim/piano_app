import AVFoundation
import Foundation

/// Seconds on the host's monotonic clock (the timebase of `AVAudioTime.hostTime` and CoreMIDI timestamps).
/// Every timestamp the coach compares — onsets, MIDI notes, player reports, timers — uses this clock.
enum MonotonicClock {
    static func now() -> Double {
        seconds(forHostTime: mach_absolute_time())
    }

    /// Converts a host time (`mach_absolute_time` ticks, as in `AVAudioTime` and `MIDITimeStamp`).
    static func seconds(forHostTime hostTime: UInt64) -> Double {
        AVAudioTime.seconds(forHostTime: hostTime)
    }
}

/// A block of mono microphone samples.
struct AudioChunk: Sendable {
    /// Mono samples (all input channels averaged).
    let samples: [Float]
    let sampleRate: Double
    /// `MonotonicClock` time of the first sample.
    let startTime: Double
}

/// Owns the microphone. One AVAudioEngine input tap feeds both the note analyser (mono float
/// chunks) and speech recognition (the original PCM buffers).
///
/// The handlers run on the audio tap's thread: they must be quick and hand work off to their own
/// queues. The tap and notification closures are `@Sendable` and formed in this non-isolated class on
/// purpose — a closure formed in a `@MainActor` context would be main-actor isolated and trap when
/// AVFoundation calls it off the main thread.
///
/// When the audio hardware changes underneath it (a new route or sample rate, an interruption ending,
/// media services resetting) the engine restarts itself, at most a few times in a row.
final class AudioInputHub: @unchecked Sendable {
    enum HubError: LocalizedError {
        case noInput
        case permissionDenied
        case stopped

        var errorDescription: String? {
            switch self {
            case .noInput: return "No microphone is available."
            case .permissionDenied: return "Microphone access is turned off. You can allow it in Settings."
            case .stopped: return "The microphone stopped and couldn't be restarted."
            }
        }
    }

    /// What asks the engine to restart.
    private enum Trigger: Sendable {
        case configurationChange(ObjectIdentifier)
        case interruptionBegan
        case interruptionEnded
        case mediaServicesReset
        case retry
    }

    private enum Outcome {
        case none
        case restarted(Double)
        case failed(Error)
    }

    private static let restartDelay = 0.25
    private static let retryDelay = 1.0
    private static let maxRestarts = 4
    private static let restartWindow = 20.0

    /// Serialises engine control (start, stop, restarts). Never taken on the tap thread, so stopping the
    /// engine can't wait for a tap block that is itself waiting for this lock.
    private let controlLock = NSLock()
    // Guarded by `controlLock`.
    private var engine = AVAudioEngine()
    private var wanted = false
    private var useVoiceProcessing = false
    private var tapInstalled = false
    private var interrupted = false
    private var recentRestarts: [Double] = []

    /// Guards the values below; held only briefly and never while calling into AVFoundation.
    private let lock = NSLock()
    private var chunkHandler: (@Sendable (AudioChunk) -> Void)?
    private var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var restartHandler: (@Sendable (Double) -> Void)?
    private var failureHandler: (@Sendable (Error) -> Void)?
    private var running = false
    private var currentSampleRate: Double = 48_000

    private var observers: [NSObjectProtocol] = []
    private let restartQueue = DispatchQueue(label: "PianoCoach.AudioInputHub.restart")

    /// Called (on an arbitrary thread) with the new sample rate after the engine restarted by itself.
    var onRestart: (@Sendable (Double) -> Void)? {
        get { lock.withLock { restartHandler } }
        set { lock.withLock { restartHandler = newValue } }
    }

    /// Called (on an arbitrary thread) when capture stopped unexpectedly and could not be restarted.
    /// `isRunning` is false by then.
    var onFailure: (@Sendable (Error) -> Void)? {
        get { lock.withLock { failureHandler } }
        set { lock.withLock { failureHandler = newValue } }
    }

    var isRunning: Bool { lock.withLock { running } }
    var sampleRate: Double { lock.withLock { currentSampleRate } }

    init() {
        let center = NotificationCenter.default
        // Observed for every engine and filtered in `recover`, because the engine is rebuilt after a
        // media services reset.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { @Sendable [weak self] note in
            guard let self, let changed = note.object as? AVAudioEngine else { return }
            self.schedule(.configurationChange(ObjectIdentifier(changed)), after: Self.restartDelay)
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { @Sendable [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                self.schedule(.interruptionBegan, after: 0)
            } else if type == .ended {
                self.schedule(.interruptionEnded, after: Self.restartDelay)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { @Sendable [weak self] _ in
            self?.schedule(.mediaServicesReset, after: Self.restartDelay)
        })
        #endif
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Receives mono chunks for note analysis.
    func setChunkHandler(_ handler: (@Sendable (AudioChunk) -> Void)?) {
        lock.withLock { chunkHandler = handler }
    }

    /// Receives the raw input buffers (for speech recognition).
    func setBufferHandler(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        lock.withLock { bufferHandler = handler }
    }

    // MARK: - Start / stop

    /// Starts capture. Safe to call when already running.
    /// - Parameter voiceProcessing: enables Apple's echo cancellation (reduces the video's sound in the
    ///   microphone signal, but also colours the piano sound; off by default). If it can't be enabled,
    ///   capture starts without it.
    func start(voiceProcessing: Bool = false) throws {
        try controlLock.withLock {
            interrupted = false
            if wanted && voiceProcessing == useVoiceProcessing && engine.isRunning { return }
            stopEngineLocked()
            useVoiceProcessing = voiceProcessing
            recentRestarts.removeAll()
            do {
                try startEngineLocked()
            } catch {
                shutDownLocked()
                throw error
            }
            wanted = true
            lock.withLock { running = true }
        }
    }

    func stop() {
        controlLock.withLock {
            guard wanted else { return }
            shutDownLocked()
        }
    }

    // MARK: - Engine (all called with `controlLock` held)

    private func startEngineLocked() throws {
        #if os(iOS)
        try Self.configureSession()
        #endif
        if useVoiceProcessing {
            do {
                try startEngineLocked(voiceProcessing: true)
                return
            } catch {
                // Echo cancellation isn't available on this device or route: listen without it.
                stopEngineLocked()
            }
        }
        try startEngineLocked(voiceProcessing: false)
    }

    private func startEngineLocked(voiceProcessing: Bool) throws {
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled != voiceProcessing {
            try input.setVoiceProcessingEnabled(voiceProcessing)
        }
        if voiceProcessing {
            // Voice-processing gain control pumps the level, which blurs piano attacks.
            input.isVoiceProcessingAGCEnabled = false
            // Duck the video only while someone is talking, and only a little.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: true, duckingLevel: .min)
        }
        // Tap at the hardware's current sample rate: after a configuration change the node keeps its
        // previous output format, and a tap at a rate the hardware doesn't run at raises an exception.
        // Voice processing advertises several junk channels; its processed signal is the mono output.
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                         channels: voiceProcessing ? 1 : min(hardware.channelCount, 2))
        else { throw HubError.noInput }

        input.removeTap(onBus: 0)
        installTap(on: input, format: format)
        tapInstalled = true
        // Prepare only after installing the tap: a prepared unit refuses the tap's format.
        engine.prepare()
        try engine.start()
        lock.withLock { currentSampleRate = format.sampleRate }
    }

    private func stopEngineLocked() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    private func shutDownLocked() {
        wanted = false
        stopEngineLocked()
        lock.withLock { running = false }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    private func installTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let sampleRate = format.sampleRate
        // 100 ms, the smallest buffer the engine reliably delivers.
        let bufferSize = AVAudioFrameCount(sampleRate / 10)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { @Sendable [weak self] buffer, when in
            guard let self else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            let start = when.isHostTimeValid
                ? MonotonicClock.seconds(forHostTime: when.hostTime)
                : MonotonicClock.now() - Double(frames) / sampleRate
            let (chunk, speech) = self.lock.withLock { (self.chunkHandler, self.bufferHandler) }
            speech?(buffer)
            guard let chunk, let data = buffer.floatChannelData else { return }
            let channels = Int(buffer.format.channelCount)
            var mono: [Float]
            if channels == 1 {
                mono = Array(UnsafeBufferPointer(start: data[0], count: frames))
            } else {
                mono = [Float](repeating: 0, count: frames)
                let scale = 1 / Float(channels)
                for c in 0..<channels {
                    let source = data[c]
                    for i in 0..<frames { mono[i] += source[i] * scale }
                }
            }
            chunk(AudioChunk(samples: mono, sampleRate: sampleRate, startTime: start))
        }
    }

    // MARK: - Recovery

    /// Runs the restart logic on `restartQueue`, never on the notifying thread: AVFoundation may post
    /// while this class holds `controlLock` (e.g. during `setActive`), and the engine must not be torn
    /// down from inside its own notification.
    private func schedule(_ trigger: Trigger, after delay: Double) {
        restartQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.recover(trigger)
        }
    }

    private func recover(_ trigger: Trigger) {
        let outcome = controlLock.withLock { recoverLocked(trigger) }
        switch outcome {
        case .none: break
        case .restarted(let rate): onRestart?(rate)
        case .failed(let error): onFailure?(error)
        }
    }

    private func recoverLocked(_ trigger: Trigger) -> Outcome {
        if case .mediaServicesReset = trigger {
            // Every audio object is invalid now; the next start needs a new engine.
            engine = AVAudioEngine()
            tapInstalled = false
            interrupted = false
        }
        guard wanted else { return .none }
        switch trigger {
        case .interruptionBegan:
            // The system stopped the engine; wait for the interruption to end.
            interrupted = true
            return .none
        case .configurationChange(let id):
            // Some changes leave the engine running (macOS posts one right after a voice-processing
            // start); restarting on those would loop.
            guard id == ObjectIdentifier(engine), !interrupted, !engine.isRunning else { return .none }
        case .retry:
            guard !interrupted, !engine.isRunning else { return .none }
        case .interruptionEnded:
            interrupted = false
        case .mediaServicesReset:
            break
        }

        let now = MonotonicClock.now()
        recentRestarts.removeAll { now - $0 > Self.restartWindow }
        guard recentRestarts.count < Self.maxRestarts else {
            shutDownLocked()
            return .failed(HubError.stopped)
        }
        recentRestarts.append(now)
        stopEngineLocked()
        do {
            try startEngineLocked()
            return .restarted(lock.withLock { currentSampleRate })
        } catch {
            if recentRestarts.count < Self.maxRestarts {
                // The hardware may still be switching routes; try again shortly.
                schedule(.retry, after: Self.retryDelay)
                return .none
            }
            shutDownLocked()
            return .failed(error)
        }
    }

    #if os(iOS)
    /// Records the piano while the video keeps playing. WebKit plays the video in its own process with
    /// its own (non-mixable) playback session, so:
    /// - `.mixWithOthers`: starting the microphone doesn't interrupt the video and vice versa.
    /// - `.defaultToSpeaker`: play-and-record would otherwise send all sound to the iPhone's earpiece.
    /// - `.allowBluetoothA2DP`, `.allowAirPlay`: headphones and speakers stay usable for the video. Not
    ///   Bluetooth HFP: that would switch a headset to call quality and listen through its microphone.
    /// - `.default` mode, not `.measurement`: measurement mode turns off output dynamics processing, which
    ///   makes the video noticeably quieter on the speaker. The onset detector adapts to the input gain
    ///   control the default mode keeps, and voice commands benefit from it.
    private static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay]
        // Restarts shouldn't reconfigure an unchanged session (that can change the route again).
        if session.category != .playAndRecord || session.mode != .default || session.categoryOptions != options {
            try session.setCategory(.playAndRecord, mode: .default, options: options)
        }
        if session.preferredSampleRate != 48_000 {
            try? session.setPreferredSampleRate(48_000)
        }
        try session.setActive(true)
    }
    #endif
}

/// Microphone and speech-recognition permission helpers.
enum Permissions {
    static func requestMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }
}
