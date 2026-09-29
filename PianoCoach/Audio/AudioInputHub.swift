import AVFoundation
import Foundation

/// Seconds on the host's monotonic clock (the same timebase as `AVAudioTime.hostTime` and CoreMIDI
/// timestamps). Every timestamp the coach compares — onsets, MIDI notes, player reports, timers — uses this clock.
enum MonotonicClock {
    static func now() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    /// Converts a host time (`mach_absolute_time` units, e.g. a `MIDITimeStamp`) to clock seconds.
    static func seconds(hostTime: UInt64) -> Double {
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
/// The handlers run on the audio tap's thread: they must be quick, hand work off to their own
/// queues and not call back into the hub. The tap and notification closures are created in this
/// non-isolated class on purpose — a closure formed in a `@MainActor` context would be main-actor
/// isolated and trap when AVFoundation calls it off the main thread.
///
/// When capture stops by itself (a route or format change, a phone call, the media services
/// restarting, the app coming back from the background) the engine is rebuilt and restarted.
/// Restarts are debounced, skipped while the engine is still running and limited in number, so a
/// device that keeps reconfiguring can't cause a restart loop.
final class AudioInputHub: @unchecked Sendable {
    enum HubError: LocalizedError {
        case noInput
        case permissionDenied
        case keepsStopping

        var errorDescription: String? {
            switch self {
            case .noInput: return "No microphone is available."
            case .permissionDenied: return "Microphone access is turned off. You can allow it in Settings."
            case .keepsStopping: return "The microphone keeps stopping. Check the audio devices and try again."
            }
        }
    }

    // Handlers. `handlerLock` is never held while calling into AVAudioEngine, so the tap can't
    // deadlock with start/stop.
    private let handlerLock = NSLock()
    private var chunkHandler: (@Sendable (AudioChunk) -> Void)?
    private var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var restartHandler: (@Sendable (Double) -> Void)?
    private var failureHandler: (@Sendable (Error) -> Void)?

    // Engine state, guarded by `stateLock`. Notification handlers never take it directly: the engine
    // posts from an internal queue that `start`/`stop` may wait on, so they hop to `restartQueue`.
    private let stateLock = NSLock()
    private var engine: AVAudioEngine?
    private var engineObserver: NSObjectProtocol?
    private var running = false
    private var useVoiceProcessing = false
    private var currentSampleRate: Double = 48_000
    private var interrupted = false
    private var recentRestarts: [Double] = []
    private var failedAttempts = 0

    // Accessed only on `restartQueue`.
    private let restartQueue = DispatchQueue(label: "PianoCoach.AudioInputHub.restart")
    private var restartPending = false
    private var restartForced = false
    private var restartProbes = false

    private var observers: [NSObjectProtocol] = []

    /// Called (on an arbitrary thread) with the new sample rate after capture restarted by itself.
    var onRestart: (@Sendable (Double) -> Void)? {
        get { handlerLock.withLock { restartHandler } }
        set { handlerLock.withLock { restartHandler = newValue } }
    }

    /// Called (on an arbitrary thread) when capture stopped unexpectedly and could not be restarted.
    var onFailure: (@Sendable (Error) -> Void)? {
        get { handlerLock.withLock { failureHandler } }
        set { handlerLock.withLock { failureHandler = newValue } }
    }

    /// Whether capture is on (including while it waits out an interruption).
    var isRunning: Bool { stateLock.withLock { running } }
    var sampleRate: Double { stateLock.withLock { currentSampleRate } }

    init() {
        let center = NotificationCenter.default
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                self?.interruptionBegan()
            } else if type == .ended {
                self?.interruptionEnded()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            self?.interruptionEnded()
        })
        #endif
        // Capture can die while the app is in the background without an interruption being
        // reported, so check whenever the app comes to the front.
        observers.append(center.addObserver(forName: Self.appDidBecomeActive, object: nil, queue: nil) { [weak self] _ in
            self?.appBecameActive()
        })
    }

    /// `UIApplication`/`NSApplication.didBecomeActiveNotification`, named by string so this class
    /// needn't import UIKit or AppKit.
    private static var appDidBecomeActive: Notification.Name {
        #if os(macOS)
        return Notification.Name("NSApplicationDidBecomeActiveNotification")
        #else
        return Notification.Name("UIApplicationDidBecomeActiveNotification")
        #endif
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
    }

    /// Receives mono chunks for note analysis.
    func setChunkHandler(_ handler: (@Sendable (AudioChunk) -> Void)?) {
        handlerLock.withLock { chunkHandler = handler }
    }

    /// Receives the raw input buffers (for speech recognition).
    func setBufferHandler(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        handlerLock.withLock { bufferHandler = handler }
    }

    // MARK: - Start / stop

    /// Starts capture. Safe to call when already running (it then only restarts a stopped engine).
    /// - Parameter voiceProcessing: enables Apple's echo cancellation (reduces the video's sound in the
    ///   microphone signal, but also colours the piano sound; off by default). If the device can't do
    ///   it, capture starts without it.
    func start(voiceProcessing: Bool = false) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if running, voiceProcessing == useVoiceProcessing, engine?.isRunning == true { return }
        teardownEngineLocked()
        running = false
        useVoiceProcessing = voiceProcessing
        interrupted = false
        recentRestarts.removeAll()
        failedAttempts = 0
        do {
            try startEngineLocked()
        } catch {
            deactivateSessionLocked()
            throw error
        }
        running = true
    }

    func stop() {
        stateLock.withLock {
            let wasActive = running || engine != nil
            running = false
            interrupted = false
            teardownEngineLocked()
            if wasActive { deactivateSessionLocked() }
        }
    }

    private func startEngineLocked() throws {
        #if os(iOS)
        try Self.configureSession()
        #endif
        do {
            try startFreshEngineLocked(voiceProcessing: useVoiceProcessing)
        } catch {
            // Echo cancellation is optional: listen without it rather than not at all.
            guard useVoiceProcessing else { throw error }
            try startFreshEngineLocked(voiceProcessing: false)
        }
    }

    /// Builds a new engine (its input node then reflects the current hardware) and starts it.
    private func startFreshEngineLocked(voiceProcessing: Bool) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Duck the video only while someone speaks, and only a little.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: true, duckingLevel: .min)
                // Keep the piano's real dynamics for the onset detector.
                input.isVoiceProcessingAGCEnabled = false
            } catch {
                // Not available on this device or route: carry on without it.
            }
        }
        var format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw HubError.noInput }
        // Voice processing on macOS can report a many-channel layout; take it as mono at the same rate.
        if format.channelCount > 2,
           let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1) {
            format = mono
        }
        installTap(on: input, format: format)

        let id = ObjectIdentifier(engine)
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.engineConfigurationChanged(id)
        }
        self.engine = engine
        engineObserver = observer
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardownEngineLocked()
            throw error
        }
        currentSampleRate = format.sampleRate
    }

    private func teardownEngineLocked() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func deactivateSessionLocked() {
        #if os(iOS)
        // Gives the video its full playback volume and routing back.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    private func installTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let sampleRate = format.sampleRate
        // 100 ms, the shortest buffer the engine supports; it may deliver a different size, which is fine.
        let bufferSize = AVAudioFrameCount(sampleRate / 10)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { @Sendable [weak self] buffer, when in
            self?.deliver(buffer, at: when, sampleRate: sampleRate)
        }
    }

    /// Runs on the tap's thread.
    private func deliver(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime, sampleRate: Double) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let start = when.isHostTimeValid
            ? MonotonicClock.seconds(hostTime: when.hostTime)
            : MonotonicClock.now() - Double(frames) / sampleRate
        let (analyse, speech) = handlerLock.withLock { (chunkHandler, bufferHandler) }
        speech?(buffer)
        // Tap buffers use the engine's standard (deinterleaved float) format.
        guard let analyse, let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        var mono = Array(UnsafeBufferPointer(start: data[0], count: frames))
        if channels > 1 {
            for c in 1..<channels {
                let src = data[c]
                for i in 0..<frames { mono[i] += src[i] }
            }
            let scale = 1 / Float(channels)
            for i in 0..<frames { mono[i] *= scale }
        }
        analyse(AudioChunk(samples: mono, sampleRate: sampleRate, startTime: start))
    }

    // MARK: - Recovery

    private func engineConfigurationChanged(_ id: ObjectIdentifier) {
        restartQueue.async { [weak self] in
            guard let self else { return }
            let current = self.stateLock.withLock { self.engine.map { ObjectIdentifier($0) } }
            if current == id { self.requestRestart() }
        }
    }

    private func interruptionBegan() {
        restartQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.withLock {
                self.interrupted = true
                self.failedAttempts = 0
            }
        }
    }

    /// The interruption ended or the media services were reset: the old engine is dead either way.
    private func interruptionEnded() {
        restartQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.withLock { self.interrupted = false }
            self.requestRestart(force: true)
        }
    }

    private func appBecameActive() {
        restartQueue.async { [weak self] in
            self?.requestRestart(probingInterruption: true)
        }
    }

    /// On `restartQueue`: coalesces a burst of notifications into one restart shortly afterwards.
    private func requestRestart(force: Bool = false, probingInterruption: Bool = false) {
        restartForced = restartForced || force
        restartProbes = restartProbes || probingInterruption
        guard !restartPending else { return }
        restartPending = true
        restartQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.restartIfNeeded()
        }
    }

    /// On `restartQueue`. Unless forced, a still-running engine is left alone: some configuration
    /// changes (e.g. voice processing rebuilding its device on macOS) don't stop it, and restarting
    /// on those would loop. During an interruption only the app coming to the front tries (an
    /// interruption doesn't always report its end); if that fails, it keeps waiting for the end.
    private func restartIfNeeded() {
        let force = restartForced
        let probe = restartProbes
        restartPending = false
        restartForced = false
        restartProbes = false

        stateLock.lock()
        let waiting = interrupted
        guard running, !waiting || probe, force || engine?.isRunning != true else {
            stateLock.unlock()
            return
        }
        let now = MonotonicClock.now()
        recentRestarts = recentRestarts.filter { now - $0 < 30 } + [now]
        if recentRestarts.count > 6 {
            giveUpLocked()
            stateLock.unlock()
            onFailure?(HubError.keepsStopping)
            return
        }
        teardownEngineLocked()
        do {
            try startEngineLocked()
            interrupted = false
            failedAttempts = 0
            let rate = currentSampleRate
            stateLock.unlock()
            onRestart?(rate)
        } catch {
            if waiting {
                stateLock.unlock()
                return
            }
            failedAttempts += 1
            let attempts = failedAttempts
            if attempts < 3 {
                stateLock.unlock()
                // Often transient (the session is still busy right after an interruption).
                restartQueue.asyncAfter(deadline: .now() + Double(attempts)) { [weak self] in
                    self?.requestRestart(force: true)
                }
            } else {
                giveUpLocked()
                stateLock.unlock()
                onFailure?(error)
            }
        }
    }

    private func giveUpLocked() {
        running = false
        failedAttempts = 0
        teardownEngineLocked()
        deactivateSessionLocked()
    }

    #if os(iOS)
    /// Records the piano while the video keeps playing.
    ///
    /// WebKit plays the video in its own process with a non-mixable playback session, so this session
    /// must mix with others or one would interrupt the other. `.defaultToSpeaker` keeps the video on the
    /// loudspeaker rather than the earpiece, and `.allowBluetoothA2DP` keeps Bluetooth headphones in
    /// stereo (the built-in microphone is used, never a headset's hands-free one). Mode `.default`
    /// rather than `.measurement`: measurement disables dynamics processing on the output and makes
    /// the video noticeably quieter, which matters when the coach learns a song from the speaker;
    /// the onset detector's adaptive threshold copes with the default input processing.
    private static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
        if session.category != .playAndRecord || session.mode != .default || session.categoryOptions != options {
            try session.setCategory(.playAndRecord, mode: .default, options: options)
        }
        try session.setActive(true)
        guard session.isInputAvailable else { throw HubError.noInput }
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
