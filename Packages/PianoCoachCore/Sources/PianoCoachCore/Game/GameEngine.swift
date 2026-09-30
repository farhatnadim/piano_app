import Foundation

/// A falling-notes piano game: moves the playhead, judges what the player plays, keeps score and
/// follows the player's pace.
///
/// Learn mode stops every chord at the line until it is played. Play mode keeps the notes moving, but
/// stops them at the next chord when the player plays nothing at all, and goes on when they play again.
/// In both, "Follow my speed" makes the speed the pace the player actually plays at (`PaceFollower`), and
/// too many mistakes in one measure start that measure again.
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
    /// Speed the game is moving towards (the player's pace, or `setSpeed`).
    public private(set) var targetSpeed: Double
    /// Per note, indexed by `ChartNote.id`.
    public private(set) var statuses: [NoteStatus]
    public private(set) var isRunning = false
    public private(set) var isFinished = false
    /// The notes are stopped at the line waiting to be played (Learn mode, or Play mode when the player
    /// has stopped).
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
    private var follower: PaceFollower
    /// The speed last reported with `.speedChanged` (the pace moves in small steps; only bigger ones are told).
    private var announcedSpeed: Double
    private var pendingEvents: [GameEvent] = []
    private let startSpeed: Double
    /// Play mode: where the playhead was when the player last played anything (right or wrong); nil until
    /// they start, and again after a measure starts over.
    private var lastInputPosition: Double?
    /// Play mode: the notes are waiting because the player stopped playing.
    private var holdingForSilence = false
    /// Mistakes so far in each measure (by the beat it starts on).
    private var mistakes: [Double: Int] = [:]
    /// Notes missed and then played again after their measure started over (they still cost accuracy).
    private var retriedMisses = 0
    private let measureStarts: [Double]

    public init(chart: NoteChart, configuration: GameConfiguration = GameConfiguration()) {
        self.chart = chart
        self.configuration = configuration
        let start = max(configuration.minSpeed, min(configuration.maxSpeed, configuration.startSpeed))
        startSpeed = start
        speed = start
        targetSpeed = start
        announcedSpeed = start
        statuses = chart.notes.map { configuration.hands.includes($0.hand) ? .pending : .notRequired }
        chords = chart.chords
            .map { $0.filter { configuration.hands.includes($0.hand) }.map(\.id) }
            .filter { !$0.isEmpty }
        follower = PaceFollower(minSpeed: configuration.minSpeed, maxSpeed: configuration.maxSpeed)
        measureStarts = chart.barLines.filter(\.isFinite).sorted()
        let firstTime = chords.first.map { chart.notes[$0[0]].time } ?? 0
        position = firstTime - configuration.leadInSeconds / chart.secondsPerBeat(atSpeed: start)
    }

    // MARK: - Running

    private var beatsPerSecond: Double { 1 / chart.secondsPerBeat(atSpeed: speed) }

    /// How late (or early) a chord may be played in Play mode, in seconds.
    private var lateWindow: Double {
        configuration.adaptiveSpeed ? max(configuration.goodWindow, configuration.followLateWindow) : configuration.goodWindow
    }

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

    /// Changes the target speed by hand (the game eases into it). Following the player starts afresh from it.
    public func setSpeed(_ newSpeed: Double) {
        let clamped = max(configuration.minSpeed, min(configuration.maxSpeed, newSpeed))
        follower.reset()
        if abs(clamped - targetSpeed) > 1e-9 {
            pendingEvents.append(.speedChanged(from: targetSpeed, to: clamped))
            targetSpeed = clamped
        }
        announcedSpeed = clamped
    }

    /// Moves the playhead to `clock`.
    public func update(to clock: Double) {
        guard isRunning, !isFinished, let last = lastClock else { return }
        let dt = max(0, min(0.25, clock - last))
        lastClock = clock
        speed += (targetSpeed - speed) * min(1, dt / 0.8)
        let proposed = position + dt * beatsPerSecond

        if nextChord < chords.count, configuration.mode == .learn || holdingForSilence {
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
        } else if configuration.mode == .play {
            if nextChord < chords.count, configuration.waitsWhenSilent, lastInputPosition == nil,
               proposed >= chartTime(ofChord: nextChord) {
                // Nothing played yet (the start, or a measure starting over): wait for the first chord.
                hold(atChord: nextChord, clock: clock)
            } else {
                position = proposed
                markLateNotesMissed(clock: clock)
            }
        } else {
            position = proposed
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

    /// Events since the last call (hits, misses, wrong notes, speed changes, restarts, finish).
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

    /// Notes still to play that fall within `beats` of the playhead (and any already due), in chart order.
    public func pendingNotes(within beats: Double) -> [ChartNote] {
        var result: [ChartNote] = []
        var c = nextChord
        while c < chords.count, chartTime(ofChord: c) <= position + beats {
            for note in chords[c] where statuses[note] == .pending { result.append(chart.notes[note]) }
            c += 1
        }
        return result
    }

    // MARK: - Judging

    /// Judges something the player played at `clock`.
    public func handle(_ onset: NoteOnset, at clock: Double) {
        guard isRunning, !isFinished else { return }
        let pos = position(at: clock)
        let bps = beatsPerSecond
        let window = configuration.goodWindow * bps
        // Following the player in Play mode, they may be a little behind the notes or ahead of them.
        let behind = configuration.mode == .play ? lateWindow * bps : window
        let ahead = configuration.mode == .learn ? max(window, configuration.earlyWindowBeats) : lateWindow * bps
        // Chords close enough to the line to be the ones the player means.
        var candidates: [Int] = []
        var c = nextChord
        while c < chords.count {
            let t = chartTime(ofChord: c)
            if t > pos + ahead { break }
            if t >= pos - behind || configuration.mode == .learn { candidates.append(c) }
            c += 1
        }
        let heldChord = holdingForSilence ? nextChord : nil
        // Anything musical counts as playing: a clap, a cough or a word doesn't.
        let isPlaying = onset.midiPitches != nil || onset.features.isPitched

        if let played = onset.midiPitches {
            for midi in played {
                if let (chord, note) = pendingNote(midi: midi, in: candidates, position: pos) {
                    judge(note: note, chord: chord, position: pos, clock: clock)
                } else if !isOtherHandNote(midi: midi, position: pos, window: window) {
                    if wrongNote(midi, clock: clock) { return }
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
                    if wrongNote(guess, clock: clock) { return }
                }
            }
        }

        guard isPlaying, configuration.mode == .play else { return }
        lastInputPosition = max(lastInputPosition ?? pos, pos)
        // Playing again after a stop: the notes go on (a chord still waiting may yet be played, late).
        if let heldChord, holdingForSilence, nextChord == heldChord {
            holdingForSilence = false
            isWaiting = false
            waitStartClock = nil
        }
    }

    /// The pending note with this pitch the player most likely means: the nearest one in time, or, when
    /// following a player who may be behind, the earliest one still open.
    private func pendingNote(midi: Int, in candidates: [Int], position pos: Double) -> (Int, Int)? {
        let inOrder = configuration.mode == .play && configuration.adaptiveSpeed
        var best: (chord: Int, note: Int, distance: Double)?
        for chord in candidates {
            for note in chords[chord] where statuses[note] == .pending && chart.notes[note].midi == midi {
                if inOrder { return (chord, note) }
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
        let offset = (pos - n.time) / beatsPerSecond      // seconds; positive = late
        let waited = isWaiting && chord == nextChord ? max(0, clock - (waitStartClock ?? clock)) : 0
        let judgement: Judgement
        if configuration.mode == .learn || waited > 0 {
            judgement = waited <= 0.35 && offset <= configuration.perfectWindow ? .perfect : .good
        } else {
            judgement = abs(offset) <= configuration.perfectWindow ? .perfect : .good
        }
        statuses[note] = .hit(judgement)
        if judgement == .perfect { stats.perfect += 1 } else { stats.good += 1 }
        pendingEvents.append(.hit(noteID: note, midi: n.midi, judgement: judgement,
                                  timingError: waited > 0 ? waited : offset))

        // A chord counts once all of its notes are played.
        guard chords[chord].allSatisfy({ statuses[$0].isDone }) else { return }
        combo += 1
        maxCombo = max(maxCombo, combo)
        let points = judgement == .perfect ? 100 : 60
        score += points * (10 + min(combo, 30)) / 10
        followPace(chord: chord, clock: clock, offset: offset, waited: waited)
        advancePastFinishedChords()
    }

    /// Lets the speed follow the pace the player plays at.
    private func followPace(chord: Int, clock: Double, offset: Double, waited: Double) {
        guard configuration.adaptiveSpeed else { return }
        if configuration.mode == .learn, waited > 0 {
            // A long stop is a pause, not slow playing; a moment to react to the note is allowed.
            if waited > configuration.stopAfter {
                follower.interrupt()
            } else {
                follower.excuse(min(waited, configuration.reactionAllowance))
            }
        }
        let lateness = configuration.mode == .play && waited == 0 ? offset : nil
        guard let next = follower.played(beat: chartTime(ofChord: chord), at: clock,
                                         secondsPerBeat: chart.secondsPerBeat(atSpeed: 1), lateness: lateness) else { return }
        targetSpeed = next
        if abs(next - announcedSpeed) >= 0.05 {
            pendingEvents.append(.speedChanged(from: announcedSpeed, to: next))
            announcedSpeed = next
        }
    }

    /// Returns true when it started the measure over.
    private func wrongNote(_ midi: Int?, clock: Double) -> Bool {
        stats.wrongNotes += 1
        pendingEvents.append(.wrongNote(midi: midi))
        guard configuration.mode == .learn else {
            combo = 0
            return false
        }
        // Learn mode can't miss notes (they wait): wrong notes are its mistakes.
        guard nextChord < chords.count else { return false }
        return countMistakes(1, atBeat: chartTime(ofChord: nextChord), clock: clock)
    }

    private func markLateNotesMissed(clock: Double) {
        let late = lateWindow * beatsPerSecond
        while nextChord < chords.count, chartTime(ofChord: nextChord) < position - late {
            let due = chartTime(ofChord: nextChord)
            // Nothing played since just before this chord: the player stopped. Wait for them at it.
            if configuration.waitsWhenSilent,
               (lastInputPosition ?? -.infinity) < due - configuration.goodWindow * beatsPerSecond * 1.5 {
                hold(atChord: nextChord, clock: clock)
                return
            }
            var missed = 0
            for note in chords[nextChord] where statuses[note] == .pending {
                statuses[note] = .missed
                stats.missed += 1
                missed += 1
                pendingEvents.append(.miss(noteID: note, midi: chart.notes[note].midi))
            }
            nextChord += 1
            if missed > 0 {
                combo = 0
                if countMistakes(missed, atBeat: due, clock: clock) { return }
            }
        }
    }

    /// Stops the notes at a chord until the player plays again (Play mode).
    private func hold(atChord index: Int, clock: Double) {
        position = chartTime(ofChord: index)
        history.removeAll()
        holdingForSilence = true
        isWaiting = true
        waitStartClock = clock
        // The stop isn't the player's pace.
        follower.interrupt()
    }

    private func advancePastFinishedChords() {
        while nextChord < chords.count, chords[nextChord].allSatisfy({ statuses[$0].isDone }) {
            nextChord += 1
            isWaiting = false
            holdingForSilence = false
            waitStartClock = nil
        }
    }

    // MARK: - Starting a measure over

    /// Adds mistakes to the measure containing `beat`; past the allowance, starts it over (returns true).
    private func countMistakes(_ count: Int, atBeat beat: Double, clock: Double) -> Bool {
        guard let allowed = configuration.mistakesAllowedPerMeasure else { return false }
        let start = measureStart(containing: beat)
        let total = (mistakes[start] ?? 0) + count
        mistakes[start] = total
        guard total > allowed else { return false }
        restartMeasure(from: start, clock: clock)
        return true
    }

    /// Goes back to `start` with every note from there on to play again, after a short lead-in; in Play
    /// mode the notes then wait for the player's first chord.
    private func restartMeasure(from start: Double, clock: Double) {
        for c in chords.indices where chartTime(ofChord: c) >= start - 1e-9 {
            for note in chords[c] {
                switch statuses[note] {
                case .hit(.perfect): stats.perfect -= 1
                case .hit: stats.good -= 1
                case .missed: retriedMisses += 1
                default: break
                }
                statuses[note] = .pending
            }
        }
        nextChord = chords.firstIndex { chart.notes[$0[0]].time >= start - 1e-9 } ?? chords.count
        position = start - configuration.restartLeadSeconds * beatsPerSecond
        history.removeAll()
        record(clock)
        combo = 0
        isWaiting = false
        holdingForSilence = false
        waitStartClock = nil
        lastInputPosition = nil
        mistakes[start] = nil
        follower.interrupt()
        pendingEvents.append(.measureRestarted(fromBeat: start))
    }

    /// The beat the measure containing `beat` starts on (bar lines, or four-beat measures without them).
    private func measureStart(containing beat: Double) -> Double {
        guard let first = measureStarts.first else { return (beat / 4 + 1e-9).rounded(.down) * 4 }
        guard beat >= first - 1e-9 else { return min(first, chords.first.map { chart.notes[$0[0]].time } ?? first) }
        var low = 0, high = measureStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if measureStarts[mid] <= beat + 1e-9 { low = mid } else { high = mid - 1 }
        }
        return measureStarts[low]
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
        let penalties = 0.5 * Double(stats.wrongNotes + retriedMisses)
        let accuracy = required == 0 ? 0 : max(0, min(1, credit / (Double(required) + penalties)))
        return GameResult(score: score, maxCombo: maxCombo, perfect: stats.perfect, good: stats.good,
                          missed: stats.missed, wrongNotes: stats.wrongNotes, accuracy: accuracy,
                          stars: GameResult.stars(forAccuracy: accuracy), startSpeed: startSpeed,
                          endSpeed: targetSpeed, mode: configuration.mode, hands: configuration.hands,
                          completed: isFinished)
    }
}
