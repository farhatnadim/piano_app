import AVFoundation
import Foundation

/// Seconds on the host's monotonic clock (the same timebase as `AVAudioTime.hostTime`).
/// Every timestamp the coach compares — onsets, player reports, timers — uses this clock.
enum MonotonicClock {
    static func now() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
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
/// queues. The tap closure is created in this non-isolated class on purpose — a closure formed in a
/// `@MainActor` context would be main-actor isolated and trap when AVFoundation calls it off the main thread.
final class AudioInputHub: @unchecked Sendable {
    enum HubError: LocalizedError {
        case noInput
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noInput: return "No microphone is available."
            case .permissionDenied: return "Microphone access is turned off. You can allow it in Settings."
            }
        }
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var chunkHandler: (@Sendable (AudioChunk) -> Void)?
    private var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var running = false
    private var currentSampleRate: Double = 48_000
    private var useVoiceProcessing = false
    private var observers: [NSObjectProtocol] = []
    private var lastStartTime: Double = -.infinity
    private let restartQueue = DispatchQueue(label: "PianoCoach.AudioInputHub.restart")

    /// Called (on an arbitrary thread) after the engine restarted because the audio route/format changed.
    var onRestart: (@Sendable (Double) -> Void)?
    /// Called (on an arbitrary thread) when capture stops unexpectedly and could not be restarted.
    var onFailure: (@Sendable (Error) -> Void)?

    var isRunning: Bool { lock.withLock { running } }
    var sampleRate: Double { lock.withLock { currentSampleRate } }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.scheduleRestart()
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended { self.scheduleRestart(force: true) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            self?.scheduleRestart(force: true)
        })
        #endif
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
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
    ///   microphone signal, but also colours the piano sound; off by default).
    func start(voiceProcessing: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        if running && voiceProcessing == useVoiceProcessing { return }
        if running { stopLocked() }
        useVoiceProcessing = voiceProcessing
        try startLocked()
    }

    func stop() {
        lock.withLock { stopLocked() }
    }

    private func startLocked() throws {
        #if os(iOS)
        try Self.configureSession()
        #endif
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled != useVoiceProcessing {
            try input.setVoiceProcessingEnabled(useVoiceProcessing)
        }
        if useVoiceProcessing {
            // Don't let echo cancellation turn the video's sound down.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw HubError.noInput }
        currentSampleRate = format.sampleRate

        input.removeTap(onBus: 0)
        installTap(on: input, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
        lastStartTime = MonotonicClock.now()
    }

    private func stopLocked() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    private func installTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let sampleRate = format.sampleRate
        // ~85 ms at 48 kHz; the engine may deliver a different size, which is fine.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            let now = MonotonicClock.now()
            let start = when.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: when.hostTime)
                : now - Double(frames) / sampleRate
            let (chunk, speech) = self.lock.withLock { (self.chunkHandler, self.bufferHandler) }
            speech?(buffer)
            guard let chunk, let data = buffer.floatChannelData else { return }
            let channels = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: frames)
            if channels == 1 {
                mono.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.update(from: data[0], count: frames)
                }
            } else {
                let scale = 1 / Float(channels)
                for c in 0..<channels {
                    let src = data[c]
                    for i in 0..<frames { mono[i] += src[i] * scale }
                }
            }
            chunk(AudioChunk(samples: mono, sampleRate: sampleRate, startTime: start))
        }
    }

    /// Restarts off the notifying thread (never while `start` holds the lock on the same thread).
    /// Configuration changes right after our own start are echoes of that start and are ignored.
    private func scheduleRestart(force: Bool = false) {
        restartQueue.async { [weak self] in
            guard let self else { return }
            let recent = self.lock.withLock { MonotonicClock.now() - self.lastStartTime < 1.0 }
            if force || !recent { self.restartAfterChange() }
        }
    }

    private func restartAfterChange() {
        lock.lock()
        guard running else { lock.unlock(); return }
        stopLocked()
        do {
            try startLocked()
            let rate = currentSampleRate
            lock.unlock()
            onRestart?(rate)
        } catch {
            lock.unlock()
            onFailure?(error)
        }
    }

    #if os(iOS)
    /// Play the video through the speaker while recording the piano.
    private static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
        try? session.setPreferredSampleRate(48_000)
        try? session.setPreferredIOBufferDuration(0.01)
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
