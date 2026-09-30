import AVFoundation
import Foundation
import Observation
import PianoCoachCore

/// Learns a song's notes: listens to its YouTube video once (or reads an audio file), writes the notes
/// down with the Basic Pitch transcription model, and arranges them into a song — tempo, key, and which
/// hand plays what — that the game can play back at any speed.
///
/// The video's sound is recorded straight from the system (`AppAudioCapture`). When that isn't possible —
/// the parent declined the recording prompt, or it records only silence — the microphone listens to the
/// video from the speaker instead, which works but hears the room too.
@MainActor
@Observable
final class SongLearner {
    enum Phase: Equatable {
        case idle
        /// Starting to record (the system may be asking for permission).
        case starting
        /// Recording while the video plays.
        case listening
        /// Writing down the notes; 0...1.
        case transcribing(Double)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Seconds of sound recorded so far.
    private(set) var heardSeconds: Double = 0
    /// 0...1 loudness of the sound being recorded, for a meter.
    private(set) var level: Float = 0
    /// True when the microphone hears the video (recording the sound directly wasn't possible).
    private(set) var usesMicrophone = false
    /// True when the last song's notes were read off the video's keyboard rather than heard.
    private(set) var readFromVideo = false

    var isListening: Bool { phase == .listening || phase == .starting }
    var isWorking: Bool {
        switch phase {
        case .idle, .failed: return false
        case .starting, .listening, .transcribing: return true
        }
    }

    /// Receives the arranged song, where its sound came from, and the piece it belongs to.
    @ObservationIgnored var onLearned: ((ArrangedSong, NotesOrigin, UUID) -> Void)?

    private let player: YouTubePlayerController
    private let audio: AudioHub
    private let collector = SampleCollector(maxSeconds: SongLearner.maxSeconds)
    /// Reads the notes off the video's keyboard, when it shows one, while its sound is recorded.
    private let videoKeys = VideoKeyReader()
    @ObservationIgnored private var capture: AppAudioCapture?
    @ObservationIgnored private var title = ""
    @ObservationIgnored private var pieceID: UUID?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    /// Bumped whenever a session starts or is cancelled, so late callbacks from an old one are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var playingSince: Double?
    /// Recording seconds minus video seconds when the video was first seen playing: turns a time in the
    /// recording into a time in the video (nil for audio files).
    @ObservationIgnored private var recordingLead: Double?
    @ObservationIgnored private var sawPlayback = false
    @ObservationIgnored private var lastPlayRequest: Double = 0

    /// Longest recording kept, so memory stays bounded (a 12-minute song is about 140 MB of samples).
    static let maxSeconds = 12.0 * 60
    /// Seconds of playback with only silence recorded before switching to the microphone.
    private static let silenceBeforeFallback = 6.0

    init(player: YouTubePlayerController, audio: AudioHub) {
        self.player = player
        self.audio = audio
    }

    // MARK: - Listening to the video

    /// Plays the video from the start and records it until it ends (or `finishListening`).
    func listenToVideo(title: String, pieceID: UUID) {
        cancel()
        self.title = title
        self.pieceID = pieceID
        let gen = generation
        collector.reset()
        heardSeconds = 0
        level = 0
        usesMicrophone = false
        sawPlayback = false
        playingSince = nil
        recordingLead = nil
        phase = .starting
        Task { [weak self] in
            guard let self else { return }
            let started = await self.startDirectCapture(generation: gen)
            guard gen == self.generation else { return }
            if !started {
                guard await self.startMicrophone(generation: gen) else {
                    guard gen == self.generation else { return }
                    self.phase = .failed("I can't hear the video: the microphone is turned off for Piano Coach. "
                                         + "You can allow it in Settings.")
                    return
                }
            }
            guard gen == self.generation else { return }
            self.phase = .listening
            self.playFromStart()
            self.monitor(generation: gen)
        }
    }

    /// Stops recording and writes down the notes heard so far.
    func finishListening() {
        guard phase == .listening else {
            // Still starting: nothing was recorded yet, and the start would otherwise carry on afterwards.
            if phase == .starting { cancel() }
            return
        }
        let gen = generation
        monitorTask?.cancel()
        player.pause()
        let recording = collector.snapshot()
        // Leave `.listening` now, so a second call (button tap and the video ending) can't transcribe twice.
        phase = .transcribing(0)
        Task { [weak self] in
            // A cancelled session's recorders were already stopped by `cancel`; don't touch a newer one's.
            guard let self, gen == self.generation else { return }
            await self.stopRecording()
            guard gen == self.generation else { return }
            guard recording.samples.count > Int(recording.sampleRate * 3) else {
                self.phase = .failed("I didn't hear enough of the song. Let the video play for a while, then try again.")
                return
            }
            Self.saveRecording(recording.samples, sampleRate: recording.sampleRate, title: self.title)
            // The keys the video lit up, in seconds of the recording.
            var seen: SeenKeys?
            let read = self.videoKeys.notes()
            if read.foundKeyboard, let start = recording.startTime {
                let notes = read.notes.map {
                    KeyboardVideoReader.VideoNote(midi: $0.midi, start: $0.start - start, end: $0.end - start, hue: $0.hue)
                }
                seen = SeenKeys(notes: notes, fullPiano: read.fullPiano)
            }
            self.transcribe(recording.samples, sampleRate: recording.sampleRate, origin: .video, seen: seen)
        }
    }

    /// Stops whatever is going on without learning anything.
    func cancel() {
        generation += 1
        monitorTask?.cancel()
        monitorTask = nil
        work?.cancel()
        work = nil
        if isListening { player.pause() }
        // Stop this session's recorders now, so a new session can't be stopped by a late cleanup.
        if usesMicrophone {
            audio.setChunkHandler(nil)
            usesMicrophone = false
        }
        if let old = capture {
            capture = nil
            Task { await old.stop() }
        }
        collector.reset()
        phase = .idle
    }

    private func playFromStart() {
        lastPlayRequest = MonotonicClock.now()
        player.setMuted(false)
        player.setRate(1)
        player.seek(to: 0)
        player.play()
    }

    private func startDirectCapture(generation gen: Int) async -> Bool {
        let collector = collector
        let keys = videoKeys
        keys.reset()
        let capture = AppAudioCapture(sink: { samples, rate, time in
            collector.append(samples, sampleRate: rate, startTime: time)
        }, videoSink: { pixels, orientation, time in
            keys.append(pixels, orientation: orientation, time: time)
        })
        do {
            try await capture.start()
            // Cancelled while the system was asking: don't leave this recording running.
            guard gen == generation else {
                await capture.stop()
                return false
            }
            self.capture = capture
            return true
        } catch {
            return false
        }
    }

    private func startMicrophone(generation gen: Int) async -> Bool {
        // Cancelled while asking for permission: don't feed a newer session (or none) from this one.
        guard await Permissions.requestMicrophone(), gen == generation else { return false }
        let collector = collector
        audio.setChunkHandler { chunk in collector.append(chunk.samples, sampleRate: chunk.sampleRate, startTime: chunk.startTime) }
        do {
            try audio.start(voiceProcessing: false)
            usesMicrophone = true
            return true
        } catch {
            audio.setChunkHandler(nil)
            return false
        }
    }

    private func stopRecording() async {
        if let capture {
            self.capture = nil
            await capture.stop()
        }
        if usesMicrophone {
            audio.setChunkHandler(nil)
            // Done with the microphone: a later `cancel` mustn't clear the note input's handler.
            usesMicrophone = false
        }
    }

    /// Follows the recording and the video: ends when the video does, and switches to the microphone
    /// when the direct recording stays silent while the video plays.
    private func monitor(generation gen: Int) {
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, gen == self.generation, self.phase == .listening else { return }
                let stats = self.collector.stats()
                self.videoKeys.setSearchRect(self.player.rectOnScreen)
                self.heardSeconds = stats.seconds
                self.level = min(1, stats.recentPeak * 2)
                let now = MonotonicClock.now()
                if self.player.state == .playing {
                    self.sawPlayback = true
                    if self.playingSince == nil {
                        self.playingSince = now
                        self.recordingLead = stats.seconds - self.player.currentTime
                    }
                } else if !self.sawPlayback, self.player.state != .buffering, now - self.lastPlayRequest > 2 {
                    // The player wasn't ready yet (or ignored the request): ask again.
                    self.playFromStart()
                }
                if let since = self.playingSince, !self.usesMicrophone, self.capture != nil,
                   now - since > Self.silenceBeforeFallback, stats.peak < 0.0005 {
                    await self.switchToMicrophone(generation: gen)
                    continue
                }
                if (self.sawPlayback && self.player.state == .ended) || stats.seconds >= Self.maxSeconds {
                    self.finishListening()
                    return
                }
            }
        }
    }

    private func switchToMicrophone(generation gen: Int) async {
        player.pause()
        if let capture {
            self.capture = nil
            await capture.stop()
        }
        guard gen == generation else { return }
        collector.reset()
        playingSince = nil
        recordingLead = nil
        sawPlayback = false
        guard await startMicrophone(generation: gen), gen == generation else {
            if gen == generation {
                phase = .failed("I can't hear the video. Turn the sound up, or allow the microphone in Settings.")
            }
            return
        }
        playFromStart()
    }

    /// Keeps the recording as a WAV file in Documents/Recordings (visible in the Files app), so a song
    /// whose notes came out wrong can be listened to, shared, and learned again from the file.
    private nonisolated static func saveRecording(_ samples: [Float], sampleRate: Double, title: String) {
        Task.detached(priority: .utility) {
            guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let folder = documents.appendingPathComponent("Recordings", isDirectory: true)
            let safeTitle = title.map { $0.isLetter || $0.isNumber || $0 == " " ? $0 : "-" }.reduce(into: "") { $0.append($1) }
            let name = safeTitle.trimmingCharacters(in: .whitespaces).isEmpty ? "Song" : safeTitle
            let url = folder.appendingPathComponent("\(name).wav")
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: url)
                let file = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                ])
                try file.write(from: buffer)
            } catch {
                // Only a convenience; the notes are still learned from the samples in memory.
            }
        }
    }

    // MARK: - Audio files

    /// Writes down the notes of an audio file (m4a, mp3, wav, aiff…).
    func learn(fromAudioFile url: URL, title: String, pieceID: UUID) {
        cancel()
        self.title = title
        self.pieceID = pieceID
        let gen = generation
        let maxSeconds = Self.maxSeconds
        recordingLead = nil
        phase = .transcribing(0)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Self.readAudioFile(url, maxSeconds: maxSeconds) }
            }.value
            guard let self, gen == self.generation else { return }
            switch result {
            case .success(let (samples, rate)):
                self.transcribe(samples, sampleRate: rate, origin: .audioFile)
            case .failure:
                self.phase = .failed("I couldn't read that file. Choose an audio file such as MP3, M4A or WAV.")
            }
        }
    }

    private nonisolated static func readAudioFile(_ url: URL, maxSeconds: Double) throws -> ([Float], Double) {
        #if canImport(Darwin)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #endif
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let total = min(file.length, AVAudioFramePosition(maxSeconds * format.sampleRate))
        let chunk: AVAudioFrameCount = 1 << 18
        guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw LearnError.noSound
        }
        var mono: [Float] = []
        mono.reserveCapacity(Int(total))
        while AVAudioFramePosition(mono.count) < total {
            let wanted = min(chunk, AVAudioFrameCount(total - AVAudioFramePosition(mono.count)))
            try file.read(into: buffer, frameCount: wanted)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            let channels = Int(format.channelCount)
            let scale = 1 / Float(channels)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += data[c][i] }
                mono.append(sum * scale)
            }
        }
        return (mono, format.sampleRate)
    }

    // MARK: - Writing down the notes

    enum LearnError: LocalizedError {
        case noSound
        case noNotes
        case noModel

        var errorDescription: String? {
            switch self {
            case .noSound: return "There was no sound to learn from."
            case .noNotes: return "I couldn't find any piano notes in that sound."
            case .noModel: return "The note model is missing from the app."
            }
        }
    }

    /// Notes read off the video's keyboard (seconds of the recording).
    struct SeenKeys: Sendable {
        var notes: [KeyboardVideoReader.VideoNote]
        var fullPiano: Bool
    }

    private func transcribe(_ samples: [Float], sampleRate: Double, origin: NotesOrigin, seen: SeenKeys? = nil) {
        guard let pieceID else { return }
        let gen = generation
        let title = self.title
        phase = .transcribing(0)
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, gen == self.generation, case .transcribing = self.phase else { return }
                self.phase = .transcribing(fraction)
            }
        }
        let job = Task.detached(priority: .userInitiated) {
            Result { try Self.makeSong(samples: samples, sampleRate: sampleRate, title: title, seen: seen, progress: report) }
        }
        work = Task { [weak self] in
            // Cancelling `work` (see `cancel`) stops the pipeline between model windows.
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self, gen == self.generation else { return }
            self.work = nil
            switch result {
            case .success(var song):
                self.phase = .idle
                self.readFromVideo = song.fromVideoKeys
                // Beat 0 in seconds of the video (the recording ran ahead of the video by `recordingLead`).
                if origin == .video, let lead = self.recordingLead {
                    song.timeOfBeatZero -= lead
                } else if origin != .video {
                    song.timeOfBeatZero = .nan
                }
                self.onLearned?(song, origin, pieceID)
            case .failure(let error) where error is CancellationError:
                self.phase = .idle
            case .failure(let error):
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// The whole pipeline, off the main thread: recording -> model -> notes -> arranged song.
    private nonisolated static func makeSong(samples: [Float], sampleRate: Double, title: String, seen: SeenKeys?,
                                             progress: @escaping @Sendable (Double) -> Void) throws -> ArrangedSong {
        guard !samples.isEmpty else { throw LearnError.noSound }
        let model = try loadModel()
        let (notes, trimmed) = try SongTranscriber.transcribe(recording: samples, sampleRate: sampleRate,
                                                              progress: { progress($0 * 0.95) }) { window in
            try Task.checkCancellation()
            return try model.run(window: window)
        }
        try Task.checkCancellation()
        // A tutorial video's lit keys are the surest notes: use them, lined up with the sound, when there
        // are enough of them; otherwise what was heard.
        var chosen = notes
        var fromVideo = false
        if let seen {
            let video = seen.notes.map {
                KeyboardVideoReader.VideoNote(midi: $0.midi, start: $0.start - trimmed, end: $0.end - trimmed, hue: $0.hue)
            }
            if let aligned = VideoNoteAligner.align(video: video, heard: notes, octaveKnown: seen.fullPiano) {
                chosen = aligned
                fromVideo = true
            }
        }
        guard var song = SongArranger.arrange(chosen, title: title) else { throw LearnError.noNotes }
        song.fromVideoKeys = fromVideo
        // Note times count from the first sound; put beat 0 back into seconds of the whole recording.
        song.timeOfBeatZero += trimmed
        progress(1)
        return song
    }

    /// The Basic Pitch model Xcode compiled into the app (or the package, compiled on first use).
    private nonisolated static func loadModel() throws -> TranscriptionModel {
        if let compiled = Bundle.main.url(forResource: "BasicPitchNMP", withExtension: "mlmodelc") {
            return try TranscriptionModel(compiledModelAt: compiled)
        }
        if let package = Bundle.main.url(forResource: "BasicPitchNMP", withExtension: "mlpackage") {
            return try TranscriptionModel(packageAt: package)
        }
        throw LearnError.noModel
    }
}

/// Collects recorded samples from any thread, at the first chunk's sample rate.
final class SampleCollector: @unchecked Sendable {
    struct Stats {
        var seconds: Double
        /// Loudest sample so far.
        var peak: Float
        /// Loudest sample in the last chunk.
        var recentPeak: Float
    }

    private let lock = NSLock()
    private let maxSeconds: Double
    private var samples: [Float] = []
    private var sampleRate: Double = 0
    private var peak: Float = 0
    private var recentPeak: Float = 0
    /// `MonotonicClock` time of the first sample.
    private var startTime: Double?

    init(maxSeconds: Double) {
        self.maxSeconds = maxSeconds
    }

    func reset() {
        lock.withLock {
            samples = []
            sampleRate = 0
            peak = 0
            recentPeak = 0
            startTime = nil
        }
    }

    func append(_ chunk: [Float], sampleRate rate: Double, startTime time: Double? = nil) {
        guard !chunk.isEmpty, rate > 0 else { return }
        lock.withLock {
            if sampleRate == 0 {
                sampleRate = rate
                startTime = time
                samples.reserveCapacity(Int(rate * 60 * 5))
            }
            guard Double(samples.count) < maxSeconds * sampleRate else { return }
            // A different rate mid-way (e.g. headphones plugged in): convert by linear interpolation.
            let converted = rate == sampleRate ? chunk : Self.interpolate(chunk, from: rate, to: sampleRate)
            var loudest: Float = 0
            for s in converted { loudest = max(loudest, abs(s)) }
            recentPeak = loudest
            peak = max(peak, loudest)
            samples.append(contentsOf: converted)
        }
    }

    func stats() -> Stats {
        lock.withLock {
            Stats(seconds: sampleRate > 0 ? Double(samples.count) / sampleRate : 0, peak: peak, recentPeak: recentPeak)
        }
    }

    func snapshot() -> (samples: [Float], sampleRate: Double, startTime: Double?) {
        lock.withLock { (samples, sampleRate, startTime) }
    }

    private static func interpolate(_ chunk: [Float], from source: Double, to target: Double) -> [Float] {
        let count = max(1, Int((Double(chunk.count) * target / source).rounded()))
        return (0..<count).map { i in
            let x = Double(i) * source / target
            let j = min(chunk.count - 1, Int(x))
            let f = Float(x - Double(j))
            return j + 1 < chunk.count ? chunk[j] * (1 - f) + chunk[j + 1] * f : chunk[j]
        }
    }
}
