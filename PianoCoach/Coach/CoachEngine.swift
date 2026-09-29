import Foundation
import Observation
import PianoCoachCore

/// Where the sheet-music cursor should be.
struct SheetPosition: Equatable {
    var sourceMeasureIndex: Int
    var beatInMeasure: Double
}

/// How the child's notes reach the app.
enum NoteSource: String, CaseIterable, Codable, Identifiable {
    case microphone
    case midiKeyboard

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .midiKeyboard: return "MIDI keyboard"
        }
    }
}

/// The coach: listens to the child, follows them through the piece and drives the video.
///
/// Pipeline: microphone (`AudioInputHub`) -> `AnalysisWorker` (onsets) -> `ScoreFollower` (where is the
/// child?) -> `PacingController` (what should the video do?) -> `YouTubePlayerController`.
/// A MIDI keyboard can replace the microphone as the note source.
@MainActor
@Observable
final class CoachEngine {
    // MARK: Observable state for the UI

    private(set) var mode: CoachMode = .off
    private(set) var status: PacingStatus = .idle
    private(set) var isListening = false
    private(set) var listeningError: String?
    /// 0...1 input level for a meter.
    private(set) var inputLevel: Float = 0
    /// Short description of the last thing heard ("C4 E4 G4" for MIDI, "♪" for the microphone).
    private(set) var lastHeard = ""
    /// Increments on every heard note (lets views pulse an indicator).
    private(set) var heardCount = 0
    /// The child's speed relative to the video, in percent, while following.
    private(set) var childSpeedPercent: Int?
    private(set) var followConfidence: Double = 0
    /// A short message for the parent (e.g. why Follow me is unavailable).
    private(set) var notice: String?

    private(set) var isLearning = false
    private(set) var learnedNoteCount = 0

    /// The reference the follower uses (from the score, or learned from the video).
    private(set) var track: FollowTrack?
    private(set) var score: Score?
    private(set) var syncMap: SyncMap?
    /// Where the sheet-music cursor should be (nil = hide cursor).
    private(set) var sheetPosition: SheetPosition?

    var loop: LoopRange? {
        didSet { if let loop, player.currentTime > loop.end || player.currentTime < loop.start - 0.5 { seek(to: loop.start) } }
    }

    /// Mute the video while the coach listens through the microphone (the microphone would otherwise hear
    /// the video's piano and think the child is playing).
    var muteVideoWhileListening = true
    var noteSource: NoteSource = .microphone {
        didSet { if oldValue != noteSource, isListening { restartListening() } }
    }
    var sensitivity: Float = 0.5 {
        didSet { analysis.setSensitivity(sensitivity) }
    }
    var echoCancellation = false {
        didSet { if oldValue != echoCancellation, isListening, noteSource == .microphone { restartListening() } }
    }
    /// Seconds between the video making a sound and the microphone analysis timestamping it.
    var learnLatency: Double = 0.08

    /// Called when a new learned track should be saved (the app persists it).
    @ObservationIgnored var onTrackLearned: ((FollowTrack) -> Void)?

    // MARK: Collaborators

    let player: YouTubePlayerController
    private let audio: AudioInputHub
    private let midi: MIDIInputManager
    private let analysis = AnalysisWorker()

    @ObservationIgnored private let pacing = PacingController()
    @ObservationIgnored private var follower: ScoreFollower?
    @ObservationIgnored private var videoClock = VideoClock()
    @ObservationIgnored private var lastOnsetClock: Double?
    @ObservationIgnored private var recorder: TrackRecorder?
    @ObservationIgnored private var learnedTrack: FollowTrack?
    @ObservationIgnored private var grouper = MIDINoteGrouper()
    @ObservationIgnored private var midiFlushTask: Task<Void, Never>?
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var lastLoopJump: Double = -.infinity
    /// Where the child last (re)started — "again" returns here.
    @ObservationIgnored private var practiceStartTime: Double = 0
    /// Speed used when the coach is off (observed so speed controls update).
    private(set) var manualRate: Double = 1
    /// Fastest speed the coach may use while following (observed copy of the pacing limit).
    private(set) var followMaxRate: Double = 1
    @ObservationIgnored private var mutedByCoach = false

    init(player: YouTubePlayerController, audio: AudioInputHub, midi: MIDIInputManager) {
        self.player = player
        self.audio = audio
        self.midi = midi
        analysis.onResult = { [weak self] onsets, level in
            self?.analysisDidProduce(onsets, levelDB: level)
        }
        let worker = analysis
        audio.onRestart = { _ in worker.reset() }
        audio.onFailure = { [weak self] error in
            Task { @MainActor in self?.audioDidFail(error) }
        }
        player.onUpdate = { [weak self] in self?.playerDidUpdate() }
        player.onExternalPlayPause = { [weak self] playing in
            guard let self else { return }
            let now = MonotonicClock.now()
            if playing { self.pacing.userDidPlay(now: now) } else { self.pacing.userDidPause(now: now) }
            self.status = self.pacing.status
        }
    }

    // MARK: - Piece

    /// Loads the coaching data for a piece. `learned` is the track learned from the video (if any).
    func attach(score: Score?, syncMap: SyncMap?, learned: FollowTrack?, manualRate: Double) {
        self.score = score
        self.syncMap = syncMap
        learnedTrack = learned
        self.manualRate = manualRate
        loop = nil
        rebuildTrack()
        setMode(.off)
        sheetPosition = nil
        notice = nil
    }

    /// Updates the score/video sync (e.g. after the parent adjusts it) without resetting the session.
    func updateSync(_ newSync: SyncMap?) {
        syncMap = newSync
        rebuildTrack()
        if mode == .followMe { resetFollower(at: player.currentTime) }
    }

    private func rebuildTrack() {
        if let score, let syncMap, !score.events.isEmpty {
            track = FollowTrack.fromScore(score, syncMap: syncMap)
        } else if let learnedTrack, !learnedTrack.isEmpty {
            track = learnedTrack
        } else {
            track = nil
        }
        if let track {
            follower = ScoreFollower(track: track,
                                     configuration: track.origin == .learnedFromVideo ? .learnedTrack : FollowerConfiguration())
        } else {
            follower = nil
        }
    }

    var canFollow: Bool { track != nil }

    var trackDescription: String {
        guard let track else { return "Not ready — learn the song or add sheet music" }
        switch track.origin {
        case .score: return "Following the sheet music (\(track.events.count) notes)"
        case .learnedFromVideo: return "Following what it learned from the video (\(track.events.count) notes)"
        }
    }

    // MARK: - Modes

    func setMode(_ newMode: CoachMode) {
        var target = newMode
        if target == .followMe && track == nil {
            notice = "To follow along, first let the coach learn the song (or add sheet music and sync it)."
            target = .waitForMe
        } else if target != .off {
            notice = nil
        }
        if isLearning && target != .off { finishLearning() }
        mode = target
        let now = MonotonicClock.now()
        pacing.setMode(target, now: now)
        if target == .off {
            player.setRate(manualRate)
            pacing.playerDidApplyRate(manualRate)
            restoreSoundIfNeeded()
        } else {
            practiceStartTime = player.currentTime
            resetFollower(at: player.currentTime)
            if noteSource == .microphone && muteVideoWhileListening && !player.isMuted {
                player.setMuted(true)
                mutedByCoach = true
            }
            if !isListening { startListening() }
        }
        status = pacing.status
        startTicking()
    }

    private func restoreSoundIfNeeded() {
        if mutedByCoach {
            player.setMuted(false)
            mutedByCoach = false
        }
    }

    private func resetFollower(at videoTime: Double) {
        follower?.reset(toVideoTime: videoTime)
        followConfidence = 0
    }

    // MARK: - Listening

    func startListening() {
        guard !isListening else { return }
        listeningError = nil
        Task { [weak self] in
            guard let self else { return }
            switch self.noteSource {
            case .microphone:
                guard await Permissions.requestMicrophone() else {
                    self.listeningError = AudioInputHub.HubError.permissionDenied.localizedDescription
                    return
                }
                let worker = self.analysis
                self.audio.setChunkHandler { chunk in worker.process(chunk) }
                do {
                    try self.audio.start(voiceProcessing: self.echoCancellation && !self.isLearning)
                    self.isListening = true
                } catch {
                    self.listeningError = "Couldn't start the microphone: \(error.localizedDescription)"
                }
            case .midiKeyboard:
                self.midi.onNoteOn = { [weak self] note, velocity, time in
                    Task { @MainActor in self?.midiNoteOn(note: note, velocity: velocity, time: time) }
                }
                do {
                    try self.midi.start()
                    self.isListening = true
                    if self.midi.sourceNames.isEmpty {
                        self.notice = "No MIDI keyboard found. Connect one with USB or Bluetooth."
                    }
                } catch {
                    self.listeningError = "Couldn't connect to MIDI: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Stops the note source (voice commands keep their own microphone use going).
    func stopListening() {
        audio.setChunkHandler(nil)
        midi.onNoteOn = nil
        midi.stop()
        isListening = false
        inputLevel = 0
    }

    private func audioDidFail(_ error: Error) {
        guard noteSource == .microphone else { return }
        isListening = false
        inputLevel = 0
        listeningError = "The microphone stopped: \(error.localizedDescription)"
    }

    private func restartListening() {
        stopListening()
        analysis.reset()
        startListening()
    }

    // MARK: - Notes in

    private func analysisDidProduce(_ onsets: [TimedOnset], levelDB: Float) {
        // Map -60...-10 dBFS to 0...1 for the meter.
        inputLevel = max(0, min(1, (levelDB + 60) / 50))
        guard noteSource == .microphone else { return }
        for timed in onsets { handle(timed.onset, at: timed.clockTime) }
    }

    private func midiNoteOn(note: Int, velocity: Int, time: Double) {
        guard noteSource == .midiKeyboard else { return }
        inputLevel = Float(velocity) / 127
        if let finished = grouper.noteOn(midi: note, velocity: velocity, time: time) {
            handle(finished, at: finished.time)
        }
        midiFlushTask?.cancel()
        let delay = grouper.window + 0.005
        midiFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if let onset = self.grouper.flushAll() { self.handle(onset, at: onset.time) }
        }
    }

    private func handle(_ onset: NoteOnset, at clockTime: Double) {
        lastOnsetClock = max(lastOnsetClock ?? clockTime, clockTime)
        heardCount &+= 1
        lastHeard = onset.midiPitches.map { $0.map(Pitch.name(midi:)).joined(separator: " ") } ?? "♪"

        if isLearning, let recorder {
            if videoClock.isPlaying(at: clockTime), let videoTime = videoClock.videoTime(at: clockTime) {
                recorder.add(onset, videoTime: videoTime)
                learnedNoteCount = recorder.eventCount
            }
            return
        }
        if mode == .followMe, let follower {
            let state = follower.process(onset, at: clockTime)
            followConfidence = state.confidence
            if let ratio = state.tempoRatio { childSpeedPercent = Int((ratio * 100).rounded()) }
            if state.jumped { practiceStartTime = state.videoTime }
        }
        tick()
    }

    // MARK: - Player updates & pacing

    private func playerDidUpdate() {
        let now = MonotonicClock.now()
        videoClock.update(videoTime: player.currentTime, rate: player.rate, isPlaying: player.isPlaying, at: now)
        if let loop, player.currentTime >= loop.end, now - lastLoopJump > 1 {
            lastLoopJump = now
            seek(to: loop.start)
        }
        if mode != .followMe { updateSheetPosition(forVideoTime: player.currentTime) }
    }

    private func startTicking() {
        tickTimer?.invalidate()
        guard mode != .off else {
            tickTimer = nil
            return
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        guard mode != .off, !isLearning else { return }
        let now = MonotonicClock.now()
        let videoTime = videoClock.videoTime(at: now) ?? player.currentTime
        pacing.configuration.rates = availableRates
        var input = PacingInput(now: now, videoTime: videoTime, videoIsPlaying: player.isPlaying,
                                currentRate: player.rate, lastOnsetClockTime: lastOnsetClock)
        if mode == .followMe, let follower {
            input.follower = follower.state
            input.childVideoTime = follower.estimatedVideoTime(at: now)
            input.expectedGapSeconds = follower.expectedGapSeconds()
            if let child = input.childVideoTime, follower.state.hasStarted {
                updateSheetPosition(forVideoTime: child, preferring: follower.currentEvent)
            }
        }
        let commands = pacing.update(input)
        for command in commands {
            if case .seek(let t) = command {
                videoClock.reset()
                player.seek(to: t)
            } else {
                player.apply(command)
            }
            if case .setRate(let r) = command { pacing.playerDidApplyRate(r) }
        }
        status = pacing.status
    }

    private func updateSheetPosition(forVideoTime videoTime: Double, preferring event: TrackEvent? = nil) {
        var position: SheetPosition?
        if let event, let m = event.sourceMeasureIndex, let b = event.beatInMeasure {
            position = SheetPosition(sourceMeasureIndex: m, beatInMeasure: b)
        } else if let score, let syncMap {
            let beat = syncMap.beat(forVideoTime: videoTime)
            if let i = score.eventIndex(atOrBefore: beat) {
                let e = score.events[i]
                position = SheetPosition(sourceMeasureIndex: e.sourceMeasureIndex, beatInMeasure: e.beatInMeasure)
            }
        }
        if position != sheetPosition { sheetPosition = position }
    }

    // MARK: - Transport (buttons and voice)

    func userPlay() {
        let now = MonotonicClock.now()
        pacing.userDidPlay(now: now)
        if mode == .followMe {
            // In follow mode the child's first note starts the video.
            resetFollower(at: player.currentTime)
        } else {
            player.play()
        }
        status = pacing.status
    }

    func userPause() {
        pacing.userDidPause(now: MonotonicClock.now())
        player.pause()
        status = pacing.status
    }

    func togglePlayPause() {
        if player.isPlaying || (mode == .followMe && status != .pausedByUser && status != .idle) {
            userPause()
        } else {
            userPlay()
        }
    }

    func seek(to seconds: Double) {
        let target = max(0, seconds)
        videoClock.reset()
        player.seek(to: target)
        practiceStartTime = target
        pacing.noteUserActivity(now: MonotonicClock.now())
        if mode == .followMe { resetFollower(at: target) }
        updateSheetPosition(forVideoTime: target)
    }

    func skip(by seconds: Double) {
        seek(to: player.currentTime + seconds)
    }

    /// Jumps to the start of a measure (needs sheet music with notes and a sync).
    @discardableResult
    func goToMeasure(_ number: Int) -> Bool {
        guard let score, let syncMap, let measure = score.measure(numbered: number) else { return false }
        seek(to: max(0, syncMap.videoTime(forBeat: measure.startBeat) - 0.3))
        return true
    }

    /// Jumps to a measure tapped on the sheet (source measure index).
    func goToSourceMeasure(_ sourceIndex: Int) {
        guard let score, let syncMap else { return }
        let current = syncMap.beat(forVideoTime: player.currentTime)
        let candidates = score.measures.filter { $0.sourceIndex == sourceIndex }
        guard let best = candidates.min(by: { abs($0.startBeat - current) < abs($1.startBeat - current) }) else { return }
        seek(to: max(0, syncMap.videoTime(forBeat: best.startBeat) - 0.3))
    }

    func goBack() {
        if let score, let syncMap {
            let beat = syncMap.beat(forVideoTime: player.currentTime)
            if let m = score.measureIndex(atBeat: beat) {
                let target = max(0, m - 1)
                seek(to: max(0, syncMap.videoTime(forBeat: score.measures[target].startBeat) - 0.3))
                return
            }
        }
        skip(by: -5)
    }

    func again() {
        if let loop { seek(to: loop.start) } else { seek(to: practiceStartTime) }
    }

    func restartPiece() {
        let start = max(0, (track?.startTime ?? 0) - 1)
        seek(to: loop?.start ?? start)
    }

    /// Loops the passage the child is working on: the current and previous measure with a score,
    /// otherwise the last ~8 seconds.
    func loopHere() {
        let t = player.currentTime
        if let score, let syncMap, let m = score.measureIndex(atBeat: syncMap.beat(forVideoTime: t)) {
            let first = score.measures[max(0, m - 1)]
            let last = score.measures[m]
            loop = LoopRange(start: max(0, syncMap.videoTime(forBeat: first.startBeat) - 0.2),
                             end: syncMap.videoTime(forBeat: last.endBeat))
        } else {
            loop = LoopRange(start: max(0, t - 8), end: t + 0.5)
        }
        practiceStartTime = loop?.start ?? t
    }

    // MARK: - Speed

    /// Rates the player supports, limited to 0.25...2.
    var availableRates: [Double] {
        let rates = player.availableRates.filter { $0 >= 0.25 && $0 <= 2 }
        return rates.isEmpty ? [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2] : rates
    }

    /// The speed used when the coach is off (or the fastest the coach may go when following).
    var speedSetting: Double {
        mode == .followMe ? followMaxRate : manualRate
    }

    func setSpeed(_ rate: Double) {
        let nearest = availableRates.min { abs($0 - rate) < abs($1 - rate) } ?? 1
        if mode == .followMe {
            pacing.configuration.maxRate = nearest
            followMaxRate = nearest
        } else {
            manualRate = nearest
            player.setRate(nearest)
            pacing.playerDidApplyRate(nearest)
        }
    }

    func stepSpeed(by steps: Int) {
        let rates = availableRates
        let current = speedSetting
        let index = rates.firstIndex { abs($0 - current) < 1e-6 } ?? (rates.firstIndex { $0 >= current } ?? rates.count - 1)
        setSpeed(rates[max(0, min(rates.count - 1, index + steps))])
    }

    /// Applies the parent's coach settings.
    func configure(silenceTimeout: Double, pauseLead: Double, allowFasterThanNormal: Bool) {
        pacing.configuration.silenceTimeout = silenceTimeout
        pacing.configuration.pauseLead = pauseLead
        pacing.configuration.resumeLead = min(0.3, pauseLead / 2)
        pacing.configuration.rates = availableRates
        if !allowFasterThanNormal { pacing.configuration.maxRate = min(pacing.configuration.maxRate, 1) }
        else if pacing.configuration.maxRate <= 1 { pacing.configuration.maxRate = 1.25 }
        followMaxRate = pacing.configuration.maxRate
    }

    // MARK: - Sound

    func setSound(on: Bool) {
        player.setMuted(!on)
        mutedByCoach = false
    }

    // MARK: - Learning the song from the video

    /// Plays the video with sound and records what the microphone hears as the reference track.
    /// Start at the beginning of the passage to learn; call `finishLearning()` when done.
    func startLearning() {
        if mode != .off { setMode(.off) }
        noteSourceBeforeLearning = noteSource
        if noteSource != .microphone { noteSource = .microphone }
        let recorder = TrackRecorder(latency: learnLatency)
        self.recorder = recorder
        learnedNoteCount = 0
        isLearning = true
        notice = "Listening to the video… keep the room quiet and the volume up."
        player.setMuted(false)
        mutedByCoach = false
        player.setRate(1)
        if isListening && echoCancellation {
            restartListening()          // echo cancellation would remove the very sound we want to learn
        } else if !isListening {
            startListening()
        }
        player.play()
    }

    @ObservationIgnored private var noteSourceBeforeLearning: NoteSource?

    /// Stops learning and merges what was heard into the learned track.
    @discardableResult
    func finishLearning() -> FollowTrack? {
        guard isLearning, let recorder else { return nil }
        isLearning = false
        player.pause()
        player.setRate(manualRate)
        let newPart = recorder.finish()
        self.recorder = nil
        if let previous = noteSourceBeforeLearning, previous != noteSource { noteSource = previous }
        noteSourceBeforeLearning = nil
        if isListening && echoCancellation && noteSource == .microphone { restartListening() }
        guard let range = recorder.coveredRange, newPart.events.count >= 4 else {
            notice = "The coach didn't hear enough notes. Turn the video's volume up and try again."
            return nil
        }
        let merged = TrackRecorder.merge(base: learnedTrack, with: newPart, replacing: range)
        learnedTrack = merged
        rebuildTrack()
        notice = "Learned \(newPart.events.count) notes. Try “Follow me”!"
        onTrackLearned?(merged)
        return merged
    }

    func cancelLearning() {
        guard isLearning else { return }
        isLearning = false
        recorder = nil
        player.pause()
        notice = nil
        if let previous = noteSourceBeforeLearning, previous != noteSource { noteSource = previous }
        noteSourceBeforeLearning = nil
        if isListening && echoCancellation && noteSource == .microphone { restartListening() }
    }

    /// Forgets the learned track (the app deletes the saved file).
    func forgetLearnedTrack() {
        learnedTrack = nil
        rebuildTrack()
        if mode == .followMe { setMode(.waitForMe) }
    }

    func clearNotice() {
        notice = nil
    }
}
