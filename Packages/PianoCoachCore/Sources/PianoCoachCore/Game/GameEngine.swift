import Foundation

/// A falling-notes piano game: moves the playhead, judges what the player plays, keeps score and
/// adapts the speed to the player.
///
/// Drive it with `update(to:)` every frame and feed it notes with `handle(_:at:)`. All times are
/// seconds on the caller's monotonic clock; positions are beats of the chart.
public final class GameEngine {
    public let chart: NoteChart
    public let configuration: GameConfiguration

    /// Playhead in beats: notes whose `time` equals it are exactly at the line. Negative during the lead-in.
    public private(set) var position: Double
    /// Current speed as a fraction of the song's tempo (eases towards `targetSpeed`).
    public private(set) var speed: Double
    /// Speed the game is moving towards (set by adaptive speed or `setSpeed`).
    public private(set) var targetSpeed: Double
    /// Per note, indexed by `ChartNote.id`.
    public private(set) var statuses: [NoteStatus]
    public private(set) var isRunning = false
    public private(set) var isFinished = false
    /// Learn mode: the notes are stopped at the line waiting to be played.
    public private(set) var isWaiting = false
    public private(set) var score = 0
    public private(set) var combo = 0
    public private(set) var maxCombo = 0
    public private(set) var stats = GameStats()

    /// Required notes grouped into chords (indices into `chart.notes`), in time order.
    private let chords: [[Int]]
    /// First chord that still has pending notes.
    private var nextChord = 0
    private var lastClock: Double?
    private var waitStartClock: Double?
    /// When the running game was last paused (so time spent paused doesn't count as waiting).
    private var pausedAtClock: Double?
    private var history: [(clock: Double, position: Double)] = []
    private var adaptive: AdaptiveSpeedController
    private var pendingEvents: [GameEvent] = []
    private let startSpeed: Double

    public init(chart: NoteChart, configuration: GameConfiguration = GameConfiguration()) {
        self.chart = chart
        self.configuration = configuration
        let start = max(configuration.minSpeed, min(configuration.maxSpeed, configuration.startSpeed))
        startSpeed = start
        speed = start
        targetSpeed = start
        statuses = chart.notes.map { configuration.hands.includes($0.hand) ? .pending : .notRequired }
        chords = chart.chords
            .map { $0.filter { configuration.hands.includes($0.hand) }.map(\.id) }
            .filter { !$0.isEmpty }
        adaptive = AdaptiveSpeedController(minSpeed: configuration.minSpeed, maxSpeed: configuration.maxSpeed)
        let firstTime = chords.first.map { chart.notes[$0[0]].time } ?? 0
        position = firstTime - configuration.leadInSeconds / chart.secondsPerBeat(atSpeed: start)
    }

    // MARK: - Running

    private var beatsPerSecond: Double { 1 / chart.secondsPerBeat(atSpeed: speed) }

    public func start(at clock: Double) {
        guard !isFinished else { return }
        if let paused = pausedAtClock, let waitStart = waitStartClock {
            waitStartClock = waitStart + max(0, clock - paused)
        }
        pausedAtClock = nil
        isRunning = true
        lastClock = clock
        record(clock)
    }

    public func pause(at clock: Double) {
        update(to: clock)
        if isRunning { pausedAtClock = clock }
        isRunning = false
        lastClock = nil
    }

    /// Changes the target speed by hand (the game eases into it).
    public func setSpeed(_ newSpeed: Double) {
        let clamped = max(configuration.minSpeed, min(configuration.maxSpeed, newSpeed))
        if abs(clamped - targetSpeed) > 1e-9 {
            pendingEvents.append(.speedChanged(from: targetSpeed, to: clamped))
            targetSpeed = clamped
        }
    }

    /// Moves the playhead to `clock`.
    public func update(to clock: Double) {
        guard isRunning, !isFinished, let last = lastClock else { return }
        let dt = max(0, min(0.25, clock - last))
        lastClock = clock
        speed += (targetSpeed - speed) * min(1, dt / 0.8)
        let proposed = position + dt * beatsPerSecond

        if configuration.mode == .learn, nextChord < chords.count {
            let due = chartTime(ofChord: nextChord)
            if proposed >= due {
                position = max(position, due)
                if !isWaiting {
                    isWaiting = true
                    waitStartClock = clock
                }
            } else {
                position = proposed
            }
        } else {
            position = proposed
            if configuration.mode == .play { markLateNotesMissed() }
        }

        if nextChord >= chords.count && position >= chart.endBeat + 0.5 {
            isFinished = true
            isRunning = false
            isWaiting = false
            pendingEvents.append(.finished)
        }
        record(clock)
    }

    /// Where the playhead was at `clock` (for judging notes heard a moment ago).
    public func position(at clock: Double) -> Double {
        guard let newest = history.last else { return position }
        if clock >= newest.clock { return position }
        for i in stride(from: history.count - 1, to: 0, by: -1) {
            let a = history[i - 1], b = history[i]
            if clock >= a.clock {
                let f = b.clock > a.clock ? (clock - a.clock) / (b.clock - a.clock) : 1
                return a.position + f * (b.position - a.position)
            }
        }
        return history[0].position
    }

    /// Events since the last call (hits, misses, wrong notes, speed changes, finish).
    public func takeEvents() -> [GameEvent] {
        defer { pendingEvents.removeAll() }
        return pendingEvents
    }

    /// Fraction of the song played (0...1).
    public var progress: Double {
        let end = chart.endBeat
        guard end > 0 else { return 0 }
        return max(0, min(1, position / end))
    }

    /// The next notes the player should play (for hinting keys).
    public var upcomingNotes: [ChartNote] {
        guard nextChord < chords.count else { return [] }
        return chords[nextChord].filter { statuses[$0] == .pending }.map { chart.notes[$0] }
    }

    // MARK: - Judging

    /// Judges something the player played at `clock`.
    public func handle(_ onset: NoteOnset, at clock: Double) {
        guard isRunning, !isFinished else { return }
        let pos = position(at: clock)
        let bps = beatsPerSecond
        let window = configuration.goodWindow * bps
        let ahead = configuration.mode == .learn ? max(window, configuration.earlyWindowBeats) : window
        // Chords close enough to the line to be the ones the player means.
        var candidates: [Int] = []
        var c = nextChord
        while c < chords.count {
            let t = chartTime(ofChord: c)
            if t > pos + ahead { break }
            if t >= pos - window || configuration.mode == .learn { candidates.append(c) }
            c += 1
        }

        if let played = onset.midiPitches {
            for midi in played {
                if let (chord, note) = nearestPending(midi: midi, in: candidates, position: pos) {
                    judge(note: note, chord: chord, position: pos, clock: clock)
                } else if !isOtherHandNote(midi: midi, position: pos, window: window) {
                    wrongNote(midi)
                }
            }
        } else {
            var best: (chord: Int, similarity: Float)?
            for chord in candidates {
                let pitches = chords[chord].filter { statuses[$0] == .pending }.map { chart.notes[$0].midi }
                guard !pitches.isEmpty else { continue }
                let sim = onset.features.similarity(to: .template(forPitches: pitches))
                if sim > (best?.similarity ?? -1) { best = (chord, sim) }
            }
            if let best, best.similarity >= configuration.chordSimilarity {
                for note in chords[best.chord] where statuses[note] == .pending {
                    judge(note: note, chord: best.chord, position: pos, clock: clock)
                }
            } else if best == nil || (best?.similarity ?? 0) < configuration.chordSimilarity * 0.7 {
                // Only a clear note can be a wrong note: a clap, a cough or a word isn't playing at all.
                guard onset.features.isPitched else { return }
                let guess = NoteTranscriber.pitches(in: onset.features, maxNotes: 1).first
                if !(guess.map { isOtherHandNote(midi: $0, position: pos, window: window) } ?? false) {
                    wrongNote(guess)
                }
            }
        }
    }

    private func nearestPending(midi: Int, in candidates: [Int], position pos: Double) -> (Int, Int)? {
        var best: (chord: Int, note: Int, distance: Double)?
        for chord in candidates {
            for note in chords[chord] where statuses[note] == .pending && chart.notes[note].midi == midi {
                let d = abs(chart.notes[note].time - pos)
                if d < (best?.distance ?? .infinity) { best = (chord, note, d) }
            }
        }
        return best.map { ($0.chord, $0.note) }
    }

    /// True if `midi` matches a nearby note of the hand that isn't being practised (not an error).
    private func isOtherHandNote(midi: Int, position pos: Double, window: Double) -> Bool {
        guard configuration.hands != .both else { return false }
        return chart.notes.contains {
            statuses[$0.id] == .notRequired && $0.midi == midi && abs($0.time - pos) <= max(window, 1)
        }
    }

    private func judge(note: Int, chord: Int, position pos: Double, clock: Double) {
        let n = chart.notes[note]
        let timingError = (pos - n.time) / beatsPerSecond      // seconds; positive = late
        let waited = isWaiting && chord == nextChord ? clock - (waitStartClock ?? clock) : 0
        let judgement: Judgement
        switch configuration.mode {
        case .play:
            judgement = abs(timingError) <= configuration.perfectWindow ? .perfect : .good
        case .learn:
            judgement = waited <= 0.35 && timingError <= configuration.perfectWindow ? .perfect : .good
        }
        statuses[note] = .hit(judgement)
        if judgement == .perfect { stats.perfect += 1 } else { stats.good += 1 }
        pendingEvents.append(.hit(noteID: note, midi: n.midi, judgement: judgement))

        // A chord counts once all of its notes are played.
        guard chords[chord].allSatisfy({ statuses[$0].isDone }) else { return }
        combo += 1
        maxCombo = max(maxCombo, combo)
        let points = judgement == .perfect ? 100 : 60
        score += points * (10 + min(combo, 30)) / 10
        let struggle = configuration.mode == .learn
            ? AdaptiveSpeedController.learnStruggle(waited: waited)
            : AdaptiveSpeedController.playStruggle(timingError: timingError, perfectWindow: configuration.perfectWindow)
        adapt(struggle)
        advancePastFinishedChords()
    }

    private func wrongNote(_ midi: Int?) {
        stats.wrongNotes += 1
        pendingEvents.append(.wrongNote(midi: midi))
        if configuration.mode == .play { combo = 0 }
        adapt(AdaptiveSpeedController.wrongNoteStruggle)
    }

    private func markLateNotesMissed() {
        let window = configuration.goodWindow * beatsPerSecond
        while nextChord < chords.count, chartTime(ofChord: nextChord) < position - window {
            var missedAny = false
            for note in chords[nextChord] where statuses[note] == .pending {
                statuses[note] = .missed
                stats.missed += 1
                missedAny = true
                pendingEvents.append(.miss(noteID: note, midi: chart.notes[note].midi))
            }
            if missedAny {
                combo = 0
                adapt(AdaptiveSpeedController.playStruggle(timingError: nil, perfectWindow: configuration.perfectWindow))
            }
            nextChord += 1
        }
    }

    private func advancePastFinishedChords() {
        while nextChord < chords.count, chords[nextChord].allSatisfy({ statuses[$0].isDone }) {
            nextChord += 1
            isWaiting = false
            waitStartClock = nil
        }
    }

    private func adapt(_ struggle: Double) {
        guard configuration.adaptiveSpeed,
              let next = adaptive.record(struggle: struggle, currentSpeed: targetSpeed) else { return }
        pendingEvents.append(.speedChanged(from: targetSpeed, to: next))
        targetSpeed = next
    }

    private func chartTime(ofChord index: Int) -> Double {
        chart.notes[chords[index][0]].time
    }

    private func record(_ clock: Double) {
        history.append((clock, position))
        if history.count > 180 { history.removeFirst(history.count - 180) }
    }

    // MARK: - Result

    public var result: GameResult {
        let required = chords.reduce(0) { $0 + $1.count }
        let credit = Double(stats.perfect) + 0.75 * Double(stats.good)
        let accuracy = required == 0 ? 0 : max(0, min(1, credit / (Double(required) + 0.5 * Double(stats.wrongNotes))))
        return GameResult(score: score, maxCombo: maxCombo, perfect: stats.perfect, good: stats.good,
                          missed: stats.missed, wrongNotes: stats.wrongNotes, accuracy: accuracy,
                          stars: GameResult.stars(forAccuracy: accuracy), startSpeed: startSpeed,
                          endSpeed: targetSpeed, mode: configuration.mode, hands: configuration.hands,
                          completed: isFinished)
    }
}
