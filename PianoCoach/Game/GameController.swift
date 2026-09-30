import Foundation
import Observation
import PianoCoachCore

/// How the notes are shown.
enum GameDisplay: String, CaseIterable, Identifiable, Codable {
    /// Falling bars above a keyboard, labelled with letter names.
    case keys
    /// A scrolling staff, to learn reading notes; notes light up when played.
    case notes

    static let storageKey = "gameDisplay"

    var id: String { rawValue }
    var displayName: String { self == .keys ? "Keys" : "Notes" }
}

/// Feedback drawn on a piano key.
enum KeyGlow: Equatable {
    /// Played by the "Watch and listen" demo.
    case pressed
    /// The right note, on time.
    case correct
    /// The right note, but pressed before its time.
    case early
    /// The right note, but pressed after its time.
    case late
    /// A note that wasn't expected, or one that was missed altogether.
    case wrong
}

/// A short celebratory message ("Perfect!", "10 in a row!", "A bit faster!").
struct Cheer: Equatable, Identifiable {
    let id: Int
    let text: String
}

/// Runs the falling-notes game for the open piece: counts in, moves the notes every frame, turns what
/// the child plays (microphone or MIDI keyboard, via `NoteInput`) into hits, and reports the result.
///
/// It also plays the song itself ("Watch"): the built-in piano plays the notes at the chosen speed while they
/// fall onto the keys — the song's rendition, which can be slowed down or sped up without losing quality.
@MainActor
@Observable
final class GameController {
    enum Phase: Equatable {
        /// No notes for this song yet (needs sheet music or a listening pass).
        case noChart
        /// Waiting for the child to press Start.
        case ready
        /// Counting down before the notes start (3, 2, 1).
        case countIn(Int)
        case playing
        case paused
        case finished
        /// The built-in piano is playing the song so the child can watch and listen (`isDemoPaused` when stopped).
        case demo
    }

    // MARK: Choices (set before a game)

    var mode: GameMode = .learn
    /// Which version of the song: everything, one note per hand, or just the tune.
    var rendition: Rendition = .full {
        didSet { if oldValue != rendition { renditionChanged() } }
    }
    var hands: HandSelection = .both
    /// Notes on the staff by default; the choice is remembered across launches.
    var display: GameDisplay = GameDisplay(rawValue: UserDefaults.standard.string(forKey: GameDisplay.storageKey) ?? "") ?? .notes {
        didSet { UserDefaults.standard.set(display.rawValue, forKey: GameDisplay.storageKey) }
    }
    var showLetters = true
    var adaptiveSpeed = true
    /// Play the hand that isn't being practised with the built-in piano.
    var accompanyOtherHand = true
    /// The built-in piano plays along: in Play mode the whole song, in time with the notes; in Learn mode
    /// (where the notes wait) each note as it is played right. On unless turned off; remembered.
    var playAlong: Bool = UserDefaults.standard.object(forKey: GameController.playAlongKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(playAlong, forKey: Self.playAlongKey) }
    }
    static let playAlongKey = "playAlong"
    /// Speed the next game starts at (the child's level for this song).
    var startSpeed: Double = 0.6

    // MARK: State for drawing

    private(set) var phase: Phase = .noChart
    /// The song's notes as learned or imported; `chart` is the chosen rendition of it.
    private(set) var fullChart: NoteChart?
    private(set) var chart: NoteChart?
    /// `chart` written as sheet music (for the Notes view), worked out once per chart.
    @ObservationIgnored private(set) var sheetMusic: SheetMusic?
    /// The Watch playback is stopped where it is (a voice "stop" or the pause button).
    private(set) var isDemoPaused = false
    private(set) var difficulty: ChartDifficulty?
    /// Playhead in beats: notes whose time equals it are at the line.
    private(set) var position: Double = 0
    private(set) var speed: Double = 0.6
    private(set) var score = 0
    private(set) var combo = 0
    private(set) var progress: Double = 0
    /// Learn mode: the notes are waiting at the line.
    private(set) var isWaiting = false
    /// Per note, indexed by `ChartNote.id`.
    private(set) var statuses: [NoteStatus] = []
    /// Keys of the next notes to play (a gentle hint on the keyboard).
    /// Keys to play soon, with how close their moment is: 0 when `hintLeadSeconds` away, 1 when due now
    /// (the key flashes as it approaches and holds steady once due).
    private(set) var upcomingKeys: [Int: Double] = [:]
    /// How long before its time a note's key starts to flash.
    static let hintLeadSeconds = 1.0
    /// Keys to light, by MIDI number.
    private(set) var keyGlows: [Int: KeyGlow] = [:]
    /// When each note was hit (clock time, by note id), for hit animations.
    private(set) var hitTimes: [Int: Double] = [:]
    private(set) var cheer: Cheer?
    private(set) var result: GameResult?
    private(set) var levelChange: LevelChange?
    /// Clock time of the latest frame (for animations).
    private(set) var frameTime: Double = 0

    /// Records a finished game (the app saves progress) and reports how the level changed.
    @ObservationIgnored var onFinished: ((GameResult) -> LevelChange?)?

    // MARK: Collaborators

    private let input: NoteInput
    private let sound: GameSoundPlayer
    @ObservationIgnored private var engine: GameEngine?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var countInTask: Task<Void, Never>?
    /// Whether games listen to the microphone or MIDI keyboard (the screenshot demo plays by itself).
    @ObservationIgnored var listensForNotes = true
    @ObservationIgnored private var glowUntil: [Int: (glow: KeyGlow, until: Double)] = [:]
    @ObservationIgnored private var cheerUntil: Double = 0
    @ObservationIgnored private var cheerCounter = 0
    @ObservationIgnored private var lastFrame: Double = 0
    @ObservationIgnored private var demoStarted: Set<Int> = []
    @ObservationIgnored private var demoEnded: Set<Int> = []
    @ObservationIgnored private var accompanied: Set<Int> = []
    @ObservationIgnored private var accompanimentEnded: Set<Int> = []
    /// Learn mode: the notes the piano sounded for the last hit and when, so the microphone hearing them
    /// isn't taken for the child playing again.
    @ObservationIgnored private var lastSounded: (pitches: [Int], at: Double)?
    /// Per key, which sounding of it is current (a later hit on the same key outlives an earlier one's release).
    @ObservationIgnored private var soundTokens: [Int: Int] = [:]
    @ObservationIgnored private var soundCounter = 0

    init(input: NoteInput, sound: GameSoundPlayer) {
        self.input = input
        self.sound = sound
    }

    // MARK: - Song

    /// Sets the song's notes and the child's level on it.
    func load(chart newChart: NoteChart?, progress: GameProgress?) {
        stop()
        fullChart = newChart
        startSpeed = progress?.speed ?? 0.6
        speed = startSpeed
        result = nil
        levelChange = nil
        applyRendition()
    }

    /// Builds `chart` from the full song for the chosen rendition and resets the start screen.
    private func applyRendition() {
        let newChart = fullChart.map { $0.rendition(rendition) }.flatMap { $0.isEmpty ? nil : $0 }
        chart = newChart
        sheetMusic = newChart.map { SheetMusic(chart: $0) }
        difficulty = newChart.map(ChartDifficulty.estimate)
        statuses = newChart.map { $0.notes.map { _ in .pending } } ?? []
        position = firstNoteTime - 4
        phase = newChart == nil ? .noChart : .ready
    }

    private func renditionChanged() {
        guard fullChart != nil else { return }
        if phase != .ready && phase != .noChart { stop() }
        result = nil
        levelChange = nil
        speed = startSpeed
        applyRendition()
    }

    private var firstNoteTime: Double { chart?.notes.first?.time ?? 0 }

    // MARK: - Playing

    /// Counts in, then starts the game (and the note listener).
    func start() {
        guard let chart else { return }
        stopDemo()
        var config = GameConfiguration()
        config.mode = mode
        config.hands = hands
        config.startSpeed = startSpeed
        config.adaptiveSpeed = adaptiveSpeed
        let engine = GameEngine(chart: chart, configuration: config)
        self.engine = engine
        statuses = engine.statuses
        position = engine.position
        speed = engine.speed
        score = 0
        combo = 0
        progress = 0
        hitTimes = [:]
        result = nil
        levelChange = nil
        accompanied = []
        accompanimentEnded = []
        lastSounded = nil
        // The whole song playing aloud would be heard by the microphone as the child's notes.
        input.playbackEchoCancellation = listensForNotes && playsWholeSong
        attachInput()
        startTimer()
        if needsSound { try? sound.start() }

        countInTask?.cancel()
        countInTask = Task { @MainActor [weak self] in
            for n in stride(from: 3, through: 1, by: -1) {
                guard let self, !Task.isCancelled else { return }
                self.phase = .countIn(n)
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.phase = .playing
            engine.start(at: MonotonicClock.now())
        }
    }

    func pause() {
        guard phase == .playing || isCountingIn else { return }
        countInTask?.cancel()
        engine?.pause(at: MonotonicClock.now())
        sound.allNotesOff()
        phase = .paused
    }

    func resume() {
        guard phase == .paused, let engine else { return }
        // The app may have stopped the listener and the piano meanwhile (e.g. it went to the background).
        if listensForNotes && !input.isListening { input.startListening() }
        if needsSound { try? sound.start() }
        phase = .playing
        engine.start(at: MonotonicClock.now())
    }

    func togglePause() {
        if phase == .paused { resume() } else { pause() }
    }

    /// Starts the same song again from the top.
    func restart() {
        start()
    }

    /// Stops any game or demo and goes back to the start screen.
    func stop() {
        countInTask?.cancel()
        countInTask = nil
        stopTimer()
        stopDemo()
        detachInput()
        sound.allNotesOff()
        engine = nil
        isWaiting = false
        upcomingKeys = [:]
        keyGlows = [:]
        glowUntil = [:]
        cheer = nil
        if chart != nil && phase != .finished { phase = .ready }
    }

    /// Leaves the results for the start screen (`stop()` keeps them showing).
    func closeResults() {
        guard phase == .finished else { return }
        stop()
        speed = startSpeed
        phase = chart == nil ? .noChart : .ready
    }

    /// Changes the speed during a game (or the starting speed before one).
    func setSpeed(_ value: Double) {
        let clamped = max(0.3, min(1.2, value))
        if let engine, phase == .playing || phase == .paused || isCountingIn {
            engine.setSpeed(clamped)
            speed = engine.speed
        } else {
            startSpeed = clamped
            speed = clamped
        }
    }

    private var isCountingIn: Bool {
        if case .countIn = phase { return true }
        return false
    }

    // MARK: - Listening to the song

    /// Plays the song with the built-in piano at the starting speed, moving the notes as a preview.
    func playDemo() {
        guard let chart, phase != .demo else { return }
        stop()
        do {
            try sound.start()
        } catch {
            showCheer("Couldn't play sound")
            return
        }
        demoStarted = []
        demoEnded = []
        isDemoPaused = false
        statuses = chart.notes.map { _ in .pending }
        position = firstNoteTime - 2
        speed = startSpeed
        progress = 0
        phase = .demo
        startTimer()
    }

    func stopDemo() {
        guard phase == .demo else { return }
        sound.allNotesOff()
        stopTimer()
        keyGlows = [:]
        glowUntil = [:]
        isDemoPaused = false
        phase = chart == nil ? .noChart : .ready
        position = firstNoteTime - 4
    }

    /// Stops the Watch playback where it is; `resumeDemo` goes on from there.
    func pauseDemo() {
        guard phase == .demo, !isDemoPaused else { return }
        isDemoPaused = true
        sound.allNotesOff()
    }

    func resumeDemo() {
        guard phase == .demo, isDemoPaused else { return }
        isDemoPaused = false
        try? sound.start()
        lastFrame = MonotonicClock.now()
    }

    func toggleDemoPause() {
        if isDemoPaused { resumeDemo() } else { pauseDemo() }
    }

    // MARK: - Voice commands

    /// "Play": starts the game, resumes it (or the Watch playback), or plays again after the results.
    func play() {
        switch phase {
        case .ready: start()
        case .paused: resume()
        case .demo: resumeDemo()
        case .finished:
            closeResults()
            start()
        case .noChart, .countIn, .playing: break
        }
    }

    /// "Stop": pauses the game or the Watch playback where it is.
    func hold() {
        switch phase {
        case .countIn, .playing: pause()
        case .demo: pauseDemo()
        case .noChart, .ready, .paused, .finished: break
        }
    }

    /// The speed now: the game's while one runs, otherwise the starting speed (also the Watch speed).
    var currentSpeed: Double {
        engine != nil && (phase == .playing || phase == .paused || isCountingIn) ? speed : startSpeed
    }

    /// "Slower" / "faster": steps the speed by `step` (e.g. -0.1).
    func changeSpeed(by step: Double) {
        setSpeed(((currentSpeed + step) * 20).rounded() / 20)
    }

    /// "Again": the Watch playback or the game from the beginning.
    func startOver() {
        if phase == .demo {
            stopDemo()
            playDemo()
        } else if chart != nil {
            if phase == .finished { closeResults() }
            start()
        }
    }

    // MARK: - Input

    /// A key pressed on the on-screen keyboard (or the Mac's keyboard): sounds it and plays it into the game.
    func tapKey(_ midi: Int) {
        try? sound.start()
        sound.noteOn(midi, velocity: 0.7)
        let release = midi
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self?.sound.noteOff(release)
        }
        guard phase == .playing, let engine else { return }
        let now = MonotonicClock.now()
        let onset = NoteOnset(time: now, strength: 1, levelDB: -20, features: .template(forPitches: [midi]),
                              midiPitches: [midi])
        engine.handle(onset, at: now)
        // The tap already sounded the key.
        consumeEvents(soundHits: false)
    }

    private func attachInput() {
        input.noteObserver = { [weak self] onset, clock in self?.heard(onset, at: clock) }
        if listensForNotes && !input.isListening { input.startListening() }
    }

    private func detachInput() {
        input.noteObserver = nil
        input.keyObserver = nil
    }

    private func heard(_ onset: NoteOnset, at clock: Double) {
        guard phase == .playing, let engine else { return }
        if isEchoOfPlayAlong(onset, at: clock, engine: engine) { return }
        // What the microphone hears shows only as the game's verdict (green or red); guessing which keys
        // it heard lit up overtones and room noise all over the keyboard.
        engine.handle(onset, at: clock)
        consumeEvents()
    }

    /// Whether the microphone just heard the piano sounding the child's last notes (Learn mode) rather
    /// than the child: it comes right after, and sounds more like those notes than like the next ones.
    private func isEchoOfPlayAlong(_ onset: NoteOnset, at clock: Double, engine: GameEngine) -> Bool {
        guard onset.midiPitches == nil, let sounded = lastSounded else { return false }
        let since = clock - sounded.at
        guard since > -0.05, since < 0.4 else { return false }
        let echo = onset.features.similarity(to: .template(forPitches: sounded.pitches))
        let next = engine.upcomingNotes.map(\.midi)
        let expected = next.isEmpty ? 0 : onset.features.similarity(to: .template(forPitches: next))
        return echo >= expected
    }

    // MARK: - Frames

    private func startTimer() {
        stopTimer()
        lastFrame = MonotonicClock.now()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func frame() {
        let now = MonotonicClock.now()
        frameTime = now
        if phase == .demo {
            demoFrame(now: now)
        } else if let engine {
            engine.update(to: now)
            position = engine.position
            speed = engine.speed
            progress = engine.progress
            isWaiting = engine.isWaiting
            upcomingKeys = Self.hints(for: engine, chart: chart, speed: speed)
            accompany(now: now)
            consumeEvents()
        }
        lastFrame = now
        if cheer != nil && now > cheerUntil { cheer = nil }
        refreshGlows(now: now)
    }

    /// Takes the engine's events. `soundHits`: in Learn mode with play-along, the piano sounds the notes
    /// played right (not for taps on the screen, which already sound).
    private func consumeEvents(soundHits: Bool = true) {
        guard let engine else { return }
        let events = engine.takeEvents()
        guard !events.isEmpty else { return }
        let now = MonotonicClock.now()
        statuses = engine.statuses
        score = engine.score
        let previousCombo = combo
        combo = engine.combo
        var hitNotes: [ChartNote] = []
        defer { if soundHits { soundPlayedNotes(hitNotes) } }
        for event in events {
            switch event {
            case .hit(let id, let midi, let judgement, let timingError):
                hitTimes[id] = now
                if let chart, chart.notes.indices.contains(id) { hitNotes.append(chart.notes[id]) }
                // On time: green. Early: orange. Late (or, in Learn mode, after a long wait): yellow.
                let verdict: KeyGlow = judgement == .perfect ? .correct : timingError < 0 ? .early : .late
                glow(midi, verdict, for: 0.35)
            case .miss(_, let midi):
                glow(midi, .wrong, for: 0.4)
            case .wrongNote(let midi):
                if let midi { glow(midi, .wrong, for: 0.4) }
            case .speedChanged(let from, let to):
                showCheer(to > from ? "Great! A bit faster" : "Let's slow down a little")
            case .finished:
                finish()
            }
        }
        if combo > previousCombo, combo > 0, combo % 10 == 0 {
            showCheer("\(combo) in a row!")
        }
    }

    private func finish() {
        guard let engine else { return }
        let outcome = engine.result
        result = outcome
        levelChange = onFinished?(outcome)
        // The next game starts at the new level ("Level up! Next time: 70 %").
        switch levelChange {
        case .up(let next)?, .down(let next)?: startSpeed = next
        default: startSpeed = max(0.3, min(1.2, outcome.endSpeed))
        }
        phase = .finished
        stopTimer()
        detachInput()
        sound.allNotesOff()
        upcomingKeys = [:]
    }

    /// The keys of the notes due within `hintLeadSeconds`, each with how close it is (0...1).
    private static func hints(for engine: GameEngine, chart: NoteChart?, speed: Double) -> [Int: Double] {
        guard let chart else { return [:] }
        let leadBeats = hintLeadSeconds / chart.secondsPerBeat(atSpeed: speed)
        let position = engine.position
        var hints: [Int: Double] = [:]
        for note in engine.pendingNotes(within: leadBeats) {
            let closeness = leadBeats > 0 ? max(0, min(1, 1 - (note.time - position) / leadBeats)) : 1
            hints[note.midi] = max(hints[note.midi] ?? 0, closeness)
        }
        return hints
    }

    /// Play mode with play-along: the piano plays the whole song, in time with the notes.
    private var playsWholeSong: Bool { playAlong && mode == .play }

    /// Whether a game makes any sound of its own.
    private var needsSound: Bool { playAlong || (accompanyOtherHand && hands != .both) }

    /// Learn mode with play-along: sounds the notes just played right, for as long as they're written
    /// (at the speed being played, at most two seconds).
    private func soundPlayedNotes(_ notes: [ChartNote]) {
        guard playAlong, mode == .learn, !notes.isEmpty, let chart else { return }
        try? sound.start()
        let secondsPerBeat = chart.secondsPerBeat(atSpeed: speed)
        for note in notes {
            soundCounter += 1
            let token = soundCounter
            soundTokens[note.midi] = token
            sound.noteOn(note.midi, velocity: Float(note.velocity ?? 0.7))
            let seconds = max(0.25, min(2, note.duration * secondsPerBeat))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                guard let self, self.soundTokens[note.midi] == token else { return }
                self.sound.noteOff(note.midi)
            }
        }
        lastSounded = (notes.map(\.midi), MonotonicClock.now())
    }

    /// Plays notes with the built-in piano as the playhead reaches them: the whole song in Play mode with
    /// play-along on, otherwise the hand that isn't practised (if chosen).
    private func accompany(now: Double) {
        guard let chart, phase == .playing else { return }
        let wholeSong = playsWholeSong
        guard wholeSong || (accompanyOtherHand && hands != .both) else { return }
        for note in chart.notes {
            if note.time > position + 0.05 { break }
            let practised = hands.includes(note.hand)
            guard wholeSong || !practised else { continue }
            if !accompanied.contains(note.id) && note.time <= position {
                accompanied.insert(note.id)
                // The child's own part a little softer than the rest, so their playing stands out.
                let level = Float(note.velocity ?? 0.6) * (practised ? 0.7 : 0.8)
                if position - note.time < 0.5 { sound.noteOn(note.midi, velocity: level) }
            }
            // Once only: a later note on the same key would otherwise be cut off every frame.
            if accompanied.contains(note.id) && !accompanimentEnded.contains(note.id) && note.end <= position {
                accompanimentEnded.insert(note.id)
                sound.noteOff(note.midi)
            }
        }
    }

    private func demoFrame(now: Double) {
        guard let chart, !isDemoPaused else { return }
        let dt = max(0, min(0.25, now - lastFrame))
        position += dt / chart.secondsPerBeat(atSpeed: speed)
        progress = max(0, min(1, position / max(0.001, chart.endBeat)))
        for note in chart.notes {
            if note.time > position { break }
            if !demoStarted.contains(note.id) {
                demoStarted.insert(note.id)
                sound.noteOn(note.midi, velocity: Float(note.velocity ?? (note.hand == .right ? 0.75 : 0.55)))
                glow(note.midi, .pressed, for: min(0.6, note.duration * chart.secondsPerBeat(atSpeed: speed)))
            }
            if !demoEnded.contains(note.id) && note.end <= position {
                demoEnded.insert(note.id)
                sound.noteOff(note.midi)
            }
        }
        if position > chart.endBeat + 1 { stopDemo() }
    }

    // MARK: - Feedback helpers

    private func glow(_ midi: Int, _ kind: KeyGlow, for seconds: Double) {
        let until = MonotonicClock.now() + seconds
        // A correct/wrong flash wins over "pressed"; a held MIDI key comes back afterwards.
        if kind == .pressed, let current = glowUntil[midi], current.glow != .pressed, current.until > MonotonicClock.now() { return }
        glowUntil[midi] = (kind, until)
    }

    private func refreshGlows(now: Double) {
        var glows: [Int: KeyGlow] = [:]
        for (midi, entry) in glowUntil {
            if entry.until > now { glows[midi] = entry.glow }
        }
        glowUntil = glowUntil.filter { $0.value.until > now }
        if glows != keyGlows { keyGlows = glows }
    }

    private func showCheer(_ text: String) {
        cheerCounter += 1
        cheer = Cheer(id: cheerCounter, text: text)
        cheerUntil = MonotonicClock.now() + 1.6
    }
}
