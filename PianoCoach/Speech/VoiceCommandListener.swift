import AVFoundation
import Foundation
import Observation
import PianoCoachCore
import Speech

/// Listens for spoken commands ("play", "stop", "slower", "faster") with Apple's speech recogniser
/// (on-device when supported), sharing the microphone with the note analyser through `AudioHub`.
///
/// Recognition runs as a chain of short tasks: a fresh one starts after every command (so the next
/// transcript starts empty), when a task ends or fails, and every ~50 s. Partial transcripts grow word by
/// word and the parser re-finds the same command in each, so a command is acted on only once it has stayed
/// the same for a moment, or when the result is final: "play" must not start the game while the child is
/// still saying "play the song". Events from a task that has been replaced are ignored.
///
/// SpeechAnalyzer (iOS/macOS 26) is not used: SFSpeechRecognizer is still supported there, covers the
/// iOS 17 / macOS 14 targets, and takes `contextualStrings` to bias it towards the command phrases.
@MainActor
@Observable
final class VoiceCommandListener {
    private(set) var isRunning = false
    /// The most recent words heard (for a small caption); cleared after a few quiet seconds.
    private(set) var lastTranscript = ""
    private(set) var errorMessage: String?
    /// Only act on commands that follow a wake word ("hey coach, slower").
    var requireWakeWord = false
    /// Extra condition under which the wake word is required, checked for every transcript — e.g. while a
    /// video with speech is playing, so someone saying "stop" in it isn't taken as a command.
    @ObservationIgnored var requireWakeWordWhen: (() -> Bool)?
    /// Receives each recognised command, on the main actor.
    @ObservationIgnored var onCommand: ((VoiceCommand) -> Void)?

    private let audio: AudioHub
    private let feed = RequestFeed()
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognizerDelegate: RecognizerDelegate?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// Identifies the current task; bumped whenever a task ends.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var taskStartedAt = 0.0
    @ObservationIgnored private var lastHeardAt = 0.0
    @ObservationIgnored private var usingOnDevice = false
    @ObservationIgnored private var allowOnDevice = true
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var isStarting = false

    /// The command in the current transcript, waiting to be stable.
    @ObservationIgnored private var pending: VoiceCommand?
    @ObservationIgnored private var pendingSince = 0.0
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var captionTask: Task<Void, Never>?

    /// Seconds a command must stay unchanged before it is acted on.
    private static let shortWindow = 0.35
    /// Used when the transcript may still grow into a different command ("play" -> "play the song",
    /// "speed seventy" -> "speed seventy five").
    private static let longWindow = 0.8
    /// Longest wait after a command first appears, even while more words keep arriving.
    private static let maxWait = 1.5
    /// Tasks are replaced at a quiet moment after this long (server recognition stops at one minute).
    private static let refreshInterval = 50.0
    private static let maxTaskAge = 58.0
    /// Last words after which a longer phrase can still turn into a different command.
    private static let continuationWords: Set<String> = [
        "play", "show", "stop", "start", "go", "repeat", "turn", "no", "reduce", "increase", "right", "left",
        "to", "the", "for", "this", "it", "me", "more", "off", "on", "just", "only",
    ]
    private static let unavailableMessage =
        "Speech recognition is unavailable right now (it may need an internet connection). Voice commands will come back by themselves."

    init(audio: AudioHub) {
        self.audio = audio
    }

    // MARK: - Start / stop

    /// Asks for microphone and speech-recognition permission, starts the microphone if needed and
    /// listens until `stop()`.
    func start() async {
        wantsRunning = true
        guard !isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        errorMessage = nil

        guard await Permissions.requestMicrophone() else {
            errorMessage = AudioHub.HubError.permissionDenied.localizedDescription
            return
        }
        let status = await Self.speechAuthorization()
        guard wantsRunning, !isRunning else { return }
        guard status == .authorized else {
            errorMessage = Self.message(for: status)
            return
        }
        if recognizer == nil, let made = Self.makeRecognizer() {
            let delegate = RecognizerDelegate(post: makePost())
            made.delegate = delegate
            recognizer = made
            recognizerDelegate = delegate
        }
        guard recognizer != nil else {
            errorMessage = "Voice commands aren't available on this device."
            return
        }
        do {
            if !audio.isRunning { try audio.start(voiceProcessing: false) }
        } catch {
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        audio.setBufferHandler(Self.makeBufferHandler(feed: feed))
        isRunning = true
        allowOnDevice = true
        consecutiveFailures = 0
        beginTask()
    }

    /// Stops recognising. The microphone keeps running for the game; the app stops it when idle.
    func stop() {
        wantsRunning = false
        audio.setBufferHandler(nil)
        restartTask?.cancel()
        restartTask = nil
        endTask()
        captionTask?.cancel()
        captionTask = nil
        if isRunning { isRunning = false }
        if !lastTranscript.isEmpty { lastTranscript = "" }
    }

    // MARK: - Recognition tasks

    /// Replaces the current task (if any) with a fresh one.
    private func beginTask() {
        restartTask?.cancel()
        restartTask = nil
        endTask()
        guard isRunning, let recognizer else { return }
        guard recognizer.isAvailable else {
            // The availability delegate usually restarts us sooner.
            errorMessage = Self.unavailableMessage
            restartRecognition(after: 10)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        usingOnDevice = allowOnDevice && recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = usingOnDevice
        request.taskHint = .search
        request.addsPunctuation = false
        request.contextualStrings = VoiceCommandParser.contextualStrings

        let gen = generation
        let post = makePost()
        feed.setRequest(request, onFormatChange: Self.makeFormatChangeHandler(generation: gen, post: post))
        task = recognizer.recognitionTask(with: request, resultHandler: Self.makeResultHandler(generation: gen, post: post))
        taskStartedAt = MonotonicClock.now()
        lastHeardAt = 0
        scheduleRefresh(generation: gen)
    }

    /// Ends the current task; anything it still reports is ignored.
    private func endTask() {
        generation += 1
        feed.setRequest(nil)?.endAudio()
        task?.cancel()
        task = nil
        refreshTask?.cancel()
        refreshTask = nil
        clearPending()
    }

    /// Starts a fresh task now, or after `delay` seconds with no task in between.
    private func restartRecognition(after delay: Double) {
        guard delay > 0 else {
            beginTask()
            return
        }
        endTask()
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            self.beginTask()
        }
    }

    /// Replaces the task after ~50 s, waiting (briefly) for a moment without new words.
    private func scheduleRefresh(generation gen: Int) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            var wait = Self.refreshInterval
            while true {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard let self, !Task.isCancelled, self.generation == gen else { return }
                let now = MonotonicClock.now()
                if now - self.lastHeardAt > 1 || now - self.taskStartedAt > Self.maxTaskAge {
                    self.restartRecognition(after: 0)
                    return
                }
                wait = 0.25
            }
        }
    }

    // MARK: - Events

    private func receive(_ event: RecognitionEvent) {
        guard isRunning else { return }
        switch event {
        case .availability(let available):
            availabilityChanged(available)
        case .formatChanged(let gen):
            if gen == generation { restartRecognition(after: 0.1) }
        case .result(let gen, let text, let isFinal):
            if gen == generation { heard(text, isFinal: isFinal) }
        case .failure(let gen, let domain, let code, let message):
            if gen == generation { recognitionFailed(domain: domain, code: code, message: message) }
        }
    }

    private func heard(_ text: String, isFinal: Bool) {
        consecutiveFailures = 0
        if errorMessage != nil { errorMessage = nil }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = words.isEmpty ? nil : VoiceCommandParser(requireWakeWord: requireWakeWord || (requireWakeWordWhen?() ?? false)).parse(words)
        if !words.isEmpty {
            lastHeardAt = MonotonicClock.now()
            showCaption(words)
        }
        if isFinal {
            if let command { fire(command) } else { restartRecognition(after: 0) }
            return
        }
        // On-device recognition can blank the transcript after a pause; that is not a change of mind.
        guard !words.isEmpty else { return }
        guard let command else {
            clearPending()
            return
        }
        let now = MonotonicClock.now()
        if command != pending {
            pending = command
            pendingSince = now
        }
        let deadline = min(now + Self.stabilityWindow(for: command, in: words), pendingSince + Self.maxWait)
        let gen = generation
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, deadline - now) * 1_000_000_000))
            guard let self, !Task.isCancelled, self.generation == gen, let command = self.pending else { return }
            self.fire(command)
        }
    }

    /// Acts on a command and starts listening afresh, so the words already heard can't trigger it again.
    private func fire(_ command: VoiceCommand) {
        restartRecognition(after: 0)
        onCommand?(command)
    }

    private func clearPending() {
        pending = nil
        pendingTask?.cancel()
        pendingTask = nil
    }

    private func recognitionFailed(domain: String, code: Int, message: String) {
        // The task is over, so its transcript won't grow any more: act on a command it already heard.
        if let command = pending {
            fire(command)
            return
        }
        let rapid = MonotonicClock.now() - taskStartedAt < 2
        consecutiveFailures = rapid ? consecutiveFailures + 1 : 0
        if rapid && !Self.isQuietError(domain: domain, code: code) {
            // E.g. a missing on-device model fails every task at once: let Apple's server try instead.
            if usingOnDevice && consecutiveFailures >= 2 { allowOnDevice = false }
            if consecutiveFailures >= 3 {
                errorMessage = "Voice commands aren't working right now (\(message)). Still trying…"
            }
        }
        let delay = consecutiveFailures == 0 ? 0.1 : min(8, 0.25 * pow(2, Double(consecutiveFailures)))
        restartRecognition(after: delay)
    }

    private func availabilityChanged(_ available: Bool) {
        if available {
            errorMessage = nil
            if task == nil { beginTask() }
        } else {
            errorMessage = Self.unavailableMessage
            restartRecognition(after: 10)
        }
    }

    private func showCaption(_ words: String) {
        let caption = words.split(separator: " ").suffix(8).joined(separator: " ")
        if caption != lastTranscript { lastTranscript = caption }
        captionTask?.cancel()
        captionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.lastTranscript = ""
        }
    }

    // MARK: - Helpers

    private static func stabilityWindow(for command: VoiceCommand, in words: String) -> Double {
        switch command {
        case .setSpeed:
            return longWindow
        default:
            let last = words.lowercased().split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
            return continuationWords.contains(last) ? longWindow : shortWindow
        }
    }

    /// "No speech detected", cancellations and transient service hiccups: restart without a message.
    private static func isQuietError(domain: String, code: Int) -> Bool {
        switch (domain, code) {
        case ("kAFAssistantErrorDomain", 203),   // retry
             ("kAFAssistantErrorDomain", 209),
             ("kAFAssistantErrorDomain", 216),   // cancelled
             ("kAFAssistantErrorDomain", 1101),  // local recording hiccup
             ("kAFAssistantErrorDomain", 1110),  // no speech detected
             ("kLSRErrorDomain", 301):           // cancelled
            return true
        default:
            return false
        }
    }

    private static func message(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .restricted:
            return "Speech recognition isn't allowed on this device."
        default:
            #if os(macOS)
            return "Speech recognition is turned off for Piano Coach. You can allow it in System Settings › Privacy & Security › Speech Recognition."
            #else
            return "Speech recognition is turned off for Piano Coach. You can allow it in Settings › Privacy & Security › Speech Recognition."
            #endif
        }
    }

    /// An English recogniser (the command phrases are English), in the user's own variant when possible.
    private static func makeRecognizer() -> SFSpeechRecognizer? {
        let current = Locale.current
        if current.language.languageCode?.identifier == "en", let recognizer = SFSpeechRecognizer(locale: current) {
            return recognizer
        }
        return SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// A thread-safe sender of events to `receive(_:)`.
    private func makePost() -> @Sendable (RecognitionEvent) -> Void {
        Self.onMain { [weak self] event in self?.receive(event) }
    }

    // The closures below are called by Speech, TCC and the audio tap on their own threads. They are built
    // in nonisolated helpers so they are never main-actor isolated (which would trap off the main thread).

    private nonisolated static func onMain(
        _ receive: @escaping @MainActor @Sendable (RecognitionEvent) -> Void
    ) -> @Sendable (RecognitionEvent) -> Void {
        { event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { receive(event) }
            }
        }
    }

    private nonisolated static func makeResultHandler(
        generation: Int,
        post: @escaping @Sendable (RecognitionEvent) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            if let result {
                post(.result(generation: generation, text: result.bestTranscription.formattedString, isFinal: result.isFinal))
            }
            if let error {
                let nsError = error as NSError
                post(.failure(generation: generation, domain: nsError.domain, code: nsError.code,
                              message: nsError.localizedDescription))
            }
        }
    }

    private nonisolated static func makeFormatChangeHandler(
        generation: Int,
        post: @escaping @Sendable (RecognitionEvent) -> Void
    ) -> @Sendable () -> Void {
        { post(.formatChanged(generation: generation)) }
    }

    private nonisolated static func makeBufferHandler(feed: RequestFeed) -> @Sendable (AVAudioPCMBuffer) -> Void {
        { buffer in feed.append(buffer) }
    }

    private nonisolated static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable newStatus in
                continuation.resume(returning: newStatus)
            }
        }
    }
}

/// What the recogniser reported, reduced to Sendable values for the hop to the main actor.
private enum RecognitionEvent: Sendable {
    case result(generation: Int, text: String, isFinal: Bool)
    case failure(generation: Int, domain: String, code: Int, message: String)
    /// The microphone's sample rate changed under the current request.
    case formatChanged(generation: Int)
    case availability(Bool)
}

/// Passes microphone buffers (on the audio thread) to the current recognition request.
private final class RequestFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var onFormatChange: (@Sendable () -> Void)?
    private var sampleRate: Double = 0

    /// Swaps in a new request (or none) and returns the previous one. No buffer reaches the previous
    /// request after this returns.
    @discardableResult
    func setRequest(_ newRequest: SFSpeechAudioBufferRecognitionRequest?,
                    onFormatChange: (@Sendable () -> Void)? = nil) -> SFSpeechAudioBufferRecognitionRequest? {
        lock.withLock {
            let old = request
            request = newRequest
            self.onFormatChange = onFormatChange
            sampleRate = 0
            return old
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let mono = Self.downmixed(buffer)
        let rate = mono.format.sampleRate
        let formatChanged: (@Sendable () -> Void)? = lock.withLock {
            guard let current = request else { return nil }
            if sampleRate == 0 { sampleRate = rate }
            guard sampleRate == rate else {
                // A request can't change sample rate midway (e.g. after a route change): stop feeding it
                // and ask for a fresh one, once.
                let report = onFormatChange
                request = nil
                onFormatChange = nil
                return report
            }
            current.append(mono)
            return nil
        }
        formatChanged?()
    }

    /// Mono copy of a multi-channel float buffer (voice processing and audio interfaces can deliver
    /// several channels).
    private static func downmixed(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let format = buffer.format
        let channels = Int(format.channelCount)
        guard channels > 1, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let source = buffer.floatChannelData,
              let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let target = mono.floatChannelData?[0] else { return buffer }
        mono.frameLength = buffer.frameLength
        let scale = 1 / Float(channels)
        for i in 0..<Int(buffer.frameLength) {
            var sum: Float = 0
            for c in 0..<channels { sum += source[c][i] }
            target[i] = sum * scale
        }
        return mono
    }
}

/// Forwards recogniser availability changes (e.g. no network for server recognition).
private final class RecognizerDelegate: NSObject, SFSpeechRecognizerDelegate {
    private let post: @Sendable (RecognitionEvent) -> Void

    init(post: @escaping @Sendable (RecognitionEvent) -> Void) {
        self.post = post
    }

    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        post(.availability(available))
    }
}
