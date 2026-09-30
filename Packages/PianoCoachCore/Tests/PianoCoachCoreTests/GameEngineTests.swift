import XCTest
@testable import PianoCoachCore

final class GameEngineTests: XCTestCase {
    /// 32 quarter notes at 100 BPM with a left-hand note on every downbeat (TestSupport's melody).
    lazy var chart = NoteChart.from(score: TestSupport.melodyScore(), title: "Melody")!

    private func midiOnset(_ pitches: [Int], at clock: Double) -> NoteOnset {
        NoteOnset(time: clock, strength: 1, levelDB: -20, features: .template(forPitches: pitches), midiPitches: pitches)
    }

    /// Runs a game at 60 frames per second. `reaction(chordTime)` decides how long after a chord reaches the
    /// line the player plays it (nil = never); `play` builds the onset from the chord's pitches.
    @discardableResult
    private func simulate(_ engine: GameEngine, seconds: Double, reaction: (Int) -> Double?,
                          play: (([ChartNote], Double) -> NoteOnset)? = nil) -> [GameEvent] {
        var events: [GameEvent] = []
        var clock = 100.0
        engine.start(at: clock)
        let chords = chart.chords.map { $0.filter { engine.configuration.hands.includes($0.hand) } }.filter { !$0.isEmpty }
        var arrived: [Int: Double] = [:]
        var played = Set<Int>()
        let make = play ?? { notes, c in self.midiOnset(notes.map(\.midi), at: c) }
        let end = clock + seconds
        while clock < end && !engine.isFinished {
            clock += 1.0 / 60
            engine.update(to: clock)
            for (i, chord) in chords.enumerated() where !played.contains(i) {
                if arrived[i] == nil, engine.position >= chord[0].time - 1e-9 { arrived[i] = clock }
                guard let at = arrived[i], let delay = reaction(i) else { continue }
                if clock >= at + delay {
                    engine.handle(make(chord, clock), at: clock)
                    played.insert(i)
                }
            }
            events += engine.takeEvents()
        }
        return events
    }

    /// Runs a game against a player who keeps their own steady pace (a fraction of the song's tempo) from the
    /// moment the first chord reaches the line, whatever the notes do; `pitches` says what they play for
    /// each chord (the chord's own notes by default).
    @discardableResult
    private func simulateOwnPace(_ engine: GameEngine, pace: Double, seconds: Double,
                                 pitches: ((Int, [ChartNote]) -> [Int])? = nil) -> [GameEvent] {
        var events: [GameEvent] = []
        var clock = 100.0
        engine.start(at: clock)
        let chords = chart.chords.map { $0.filter { engine.configuration.hands.includes($0.hand) } }.filter { !$0.isEmpty }
        let secondsPerBeat = chart.secondsPerBeat(atSpeed: pace)
        var begin: Double?
        var next = 0
        let end = clock + seconds
        while clock < end && !engine.isFinished {
            clock += 1.0 / 60
            engine.update(to: clock)
            if begin == nil, engine.position >= chords[0][0].time - 1e-9 { begin = clock }
            if let begin, next < chords.count,
               clock >= begin + (chords[next][0].time - chords[0][0].time) * secondsPerBeat {
                let notes = chords[next]
                engine.handle(midiOnset(pitches?(next, notes) ?? notes.map(\.midi), at: clock), at: clock)
                next += 1
            }
            events += engine.takeEvents()
        }
        return events
    }

    private func restarts(in events: [GameEvent]) -> [Double] {
        events.compactMap { if case .measureRestarted(let beat) = $0 { return beat } else { return nil } }
    }

    func testLearnModeWaitsAtTheLineUntilPlayed() {
        var config = GameConfiguration()
        config.mode = .learn
        config.adaptiveSpeed = false
        let engine = GameEngine(chart: chart, configuration: config)
        XCTAssertLessThan(engine.position, 0, "starts with a lead-in")
        engine.start(at: 0)
        var clock = 0.0
        for _ in 0..<600 { clock += 1.0 / 60; engine.update(to: clock) }     // 10 s, nobody plays
        XCTAssertTrue(engine.isWaiting)
        XCTAssertEqual(engine.position, chart.notes[0].time, accuracy: 1e-9)
        XCTAssertEqual(engine.upcomingNotes.map(\.midi), [48, 64])
        // A wrong key doesn't move on.
        engine.handle(midiOnset([61], at: clock), at: clock)
        XCTAssertTrue(engine.isWaiting)
        XCTAssertEqual(engine.takeEvents().last, .wrongNote(midi: 61))
        // Playing one note of the chord isn't enough; both are.
        engine.handle(midiOnset([64], at: clock), at: clock)
        XCTAssertTrue(engine.isWaiting)
        engine.handle(midiOnset([48], at: clock), at: clock)
        XCTAssertFalse(engine.isWaiting)
        XCTAssertEqual(engine.statuses[0], .hit(.good))   // waited long: good, not perfect
        clock += 0.1
        engine.update(to: clock)
        XCTAssertGreaterThan(engine.position, chart.notes[0].time)
    }

    func testLearnModeTimeSpentPausedDoesNotCountAsWaiting() {
        var config = GameConfiguration()
        config.mode = .learn
        config.adaptiveSpeed = false
        let engine = GameEngine(chart: chart, configuration: config)
        engine.start(at: 0)
        var clock = 0.0
        while !engine.isWaiting { clock += 1.0 / 60; engine.update(to: clock) }
        // Paused a moment after the chord reached the line, then resumed a minute later.
        engine.pause(at: clock + 0.1)
        clock += 60
        engine.start(at: clock)
        clock += 0.05
        engine.update(to: clock)
        engine.handle(midiOnset([48, 64], at: clock), at: clock)
        XCTAssertEqual(engine.statuses[0], .hit(.perfect))
        XCTAssertEqual(engine.statuses[1], .hit(.perfect))
    }

    func testPlayModePerfectPlayerGetsThreeStars() {
        var config = GameConfiguration()
        config.mode = .play
        config.startSpeed = 1
        config.adaptiveSpeed = false
        let engine = GameEngine(chart: chart, configuration: config)
        simulate(engine, seconds: 60, reaction: { _ in 0.02 })
        XCTAssertTrue(engine.isFinished)
        let result = engine.result
        XCTAssertEqual(result.perfect, chart.notes.count)
        XCTAssertEqual(result.missed, 0)
        XCTAssertEqual(result.maxCombo, chart.chords.count)
        XCTAssertEqual(result.stars, 3)
        XCTAssertTrue(result.completed)
    }

    func testPlayModeWaitsForTheFirstNote() {
        var config = GameConfiguration()
        config.mode = .play
        config.startSpeed = 1
        let engine = GameEngine(chart: chart, configuration: config)
        simulate(engine, seconds: 10, reaction: { _ in nil })
        XCTAssertTrue(engine.isWaiting)
        XCTAssertEqual(engine.position, chart.notes[0].time, accuracy: 1e-9)
        XCTAssertEqual(engine.stats.missed, 0)
    }

    func testPlayModeStopsWhenThePlayerStopsAndGoesOnWhenTheyPlayAgain() {
        var config = GameConfiguration()
        config.mode = .play
        config.startSpeed = 1
        config.adaptiveSpeed = false
        let engine = GameEngine(chart: chart, configuration: config)
        // Plays the first 10 chords, then stops.
        simulate(engine, seconds: 30, reaction: { $0 < 10 ? 0.02 : nil })
        XCTAssertFalse(engine.isFinished)
        XCTAssertTrue(engine.isWaiting, "the notes wait at the next chord")
        XCTAssertEqual(engine.stats.missed, 0, "nothing is missed while the player isn't playing")
        let waitingAt = engine.position
        XCTAssertEqual(engine.upcomingNotes.first?.time ?? -1, waitingAt, accuracy: 1e-9)
        // Playing that chord again sets the notes going.
        var clock = 200.0
        engine.start(at: clock)
        engine.handle(midiOnset(engine.upcomingNotes.map(\.midi), at: clock), at: clock)
        XCTAssertFalse(engine.isWaiting)
        clock += 0.5
        engine.update(to: clock)
        XCTAssertGreaterThan(engine.position, waitingAt)
    }

    func testPlayModeWithoutWaitingKeepsGoingAndMisses() {
        var config = GameConfiguration()
        config.mode = .play
        config.startSpeed = 1
        config.adaptiveSpeed = false
        config.waitsWhenSilent = false
        config.mistakesAllowedPerMeasure = nil
        let engine = GameEngine(chart: chart, configuration: config)
        simulate(engine, seconds: 60, reaction: { $0 < 10 ? 0.05 : nil })
        XCTAssertTrue(engine.isFinished)
        XCTAssertGreaterThan(engine.result.missed, 10)
        XCTAssertEqual(engine.combo, 0)
        XCTAssertLessThan(engine.result.stars, 3)
    }

    func testFollowMySpeedSlowsDownToAPlayerWhoPlaysMoreSlowly() {
        var config = GameConfiguration()
        config.mode = .play
        config.startSpeed = 0.8
        let engine = GameEngine(chart: chart, configuration: config)
        let events = simulateOwnPace(engine, pace: 0.55, seconds: 30)
        XCTAssertEqual(engine.targetSpeed, 0.55, accuracy: 0.07)
        XCTAssertLessThanOrEqual(engine.stats.missed, 1)
        XCTAssertEqual(restarts(in: events), [])
        XCTAssertTrue(events.contains { if case .speedChanged(let from, let to) = $0 { return to < from } else { return false } })
    }

    func testFollowMySpeedSpeedsUpForAPlayerWhoPlaysFaster() {
        var config = GameConfiguration()
        config.mode = .play
        config.startSpeed = 0.6
        let engine = GameEngine(chart: chart, configuration: config)
        let events = simulateOwnPace(engine, pace: 0.8, seconds: 25)
        XCTAssertEqual(engine.targetSpeed, 0.8, accuracy: 0.08)
        XCTAssertLessThanOrEqual(engine.stats.missed, 1)
        XCTAssertEqual(restarts(in: events), [])
    }

    func testLearnModeFollowsTheSpeedOfAQuickPlayerAndOfASlowOne() {
        var config = GameConfiguration()
        config.mode = .learn
        config.startSpeed = 0.6
        // Plays ahead of the notes: they speed up.
        let quick = GameEngine(chart: chart, configuration: config)
        simulateOwnPace(quick, pace: 0.8, seconds: 40)
        XCTAssertGreaterThan(quick.result.endSpeed, 0.7)
        XCTAssertEqual(quick.result.wrongNotes, 0)

        // Much slower than the notes: they slow down (short reactions to a waiting note don't count).
        let slow = GameEngine(chart: chart, configuration: config)
        simulateOwnPace(slow, pace: 0.35, seconds: 120)
        XCTAssertLessThan(slow.result.endSpeed, 0.5)
        XCTAssertTrue(slow.isFinished)
        XCTAssertEqual(slow.result.missed, 0, "learn mode never misses")

        // Waits for each note and plays it a moment after it arrives: the speed stays put.
        let steady = GameEngine(chart: chart, configuration: config)
        simulate(steady, seconds: 120, reaction: { _ in 0.3 })
        XCTAssertEqual(steady.result.endSpeed, 0.6, accuracy: 0.06)
    }

    func testPlayModeStartsAMeasureAgainAfterMoreThanThreeMisses() {
        var config = GameConfiguration()
        config.mode = .play
        config.startSpeed = 1
        config.adaptiveSpeed = false
        let engine = GameEngine(chart: chart, configuration: config)
        // Plays a wrong key for every chord (once): measure 1 has 5 notes, the 4th miss (in its 3rd chord)
        // starts it again.
        let events = simulate(engine, seconds: 10, reaction: { _ in 0.02 }, play: { _, clock in self.midiOnset([30], at: clock) })
        XCTAssertEqual(restarts(in: events), [0])
        XCTAssertEqual(engine.statuses[0], .pending)
        XCTAssertEqual(engine.statuses[1], .pending)
        XCTAssertEqual(engine.combo, 0)
        // Then the notes wait at the start of the measure for the player to begin again.
        XCTAssertTrue(engine.isWaiting)
        XCTAssertEqual(engine.position, 0, accuracy: 1e-9)
        // The misses still count against the game.
        XCTAssertEqual(engine.result.missed, 4)
    }

    func testLearnModeStartsAMeasureAgainAfterMoreThanThreeWrongNotes() {
        var config = GameConfiguration()
        config.mode = .learn
        config.adaptiveSpeed = false
        let engine = GameEngine(chart: chart, configuration: config)
        engine.start(at: 0)
        var clock = 0.0
        while !engine.isWaiting { clock += 1.0 / 60; engine.update(to: clock) }
        engine.handle(midiOnset([48, 64], at: clock), at: clock)      // measure 1, beat 1: right
        while !engine.isWaiting { clock += 1.0 / 60; engine.update(to: clock) }
        for _ in 0..<3 { engine.handle(midiOnset([30], at: clock), at: clock) }
        XCTAssertEqual(restarts(in: engine.takeEvents()), [], "three wrong notes are allowed")
        engine.handle(midiOnset([30], at: clock), at: clock)
        XCTAssertEqual(restarts(in: engine.takeEvents()), [0])
        XCTAssertEqual(engine.statuses[0], .pending, "the measure's first chord is to play again")
        XCTAssertEqual(engine.upcomingNotes.map(\.midi), [48, 64])
        XCTAssertLessThan(engine.position, 0)
    }

    func testRightHandOnlyDoesNotRequireOrPunishLeftHand() {
        var config = GameConfiguration()
        config.mode = .play
        config.hands = .right
        config.startSpeed = 1
        config.adaptiveSpeed = false
        let engine = GameEngine(chart: chart, configuration: config)
        XCTAssertEqual(engine.statuses[0], .notRequired)          // the C3 bass note
        // The player also plays the bass notes: no wrong notes.
        let events = simulate(engine, seconds: 60, reaction: { _ in 0.02 }, play: { notes, clock in
            let time = notes[0].time
            let bass = self.chart.notes.filter { $0.hand == .left && abs($0.time - time) < 1e-6 }.map(\.midi)
            return self.midiOnset(notes.map(\.midi) + bass, at: clock)
        })
        XCTAssertFalse(events.contains { if case .wrongNote = $0 { return true } else { return false } })
        XCTAssertEqual(engine.result.perfect, chart.notes.filter { $0.hand == .right }.count)
    }

    func testMicrophoneFeaturesCountAsHits() {
        var config = GameConfiguration()
        config.mode = .play
        config.startSpeed = 1
        config.adaptiveSpeed = false
        let engine = GameEngine(chart: chart, configuration: config)
        simulate(engine, seconds: 60, reaction: { _ in 0.03 }, play: { notes, clock in
            TestSupport.onset(notes.map(\.midi), at: clock, noise: 0.3, seed: Int(clock * 1000))
        })
        XCTAssertTrue(engine.isFinished)
        XCTAssertGreaterThan(engine.result.accuracy, 0.9)
        XCTAssertEqual(engine.result.wrongNotes, 0)
    }

    func testPositionHistoryInterpolates() {
        var config = GameConfiguration()
        config.mode = .play
        config.startSpeed = 1
        config.adaptiveSpeed = false
        let engine = GameEngine(chart: chart, configuration: config)
        engine.start(at: 0)
        engine.update(to: 0.1)
        let p1 = engine.position
        engine.update(to: 0.2)
        let p2 = engine.position
        XCTAssertEqual(engine.position(at: 0.15), (p1 + p2) / 2, accuracy: 1e-9)
        XCTAssertEqual(engine.position(at: 0.3), p2, accuracy: 1e-9)
    }

    func testProgressLevelsUpAfterAGreatGameAndDownAfterAHardOne() {
        var progress = GameProgress(speed: 0.6)
        XCTAssertEqual(progress.level, 6)
        func result(accuracy: Double, end: Double, completed: Bool = true) -> GameResult {
            GameResult(score: 1000, maxCombo: 10, perfect: 10, good: 0, missed: 0, wrongNotes: 0, accuracy: accuracy,
                       stars: GameResult.stars(forAccuracy: accuracy), startSpeed: 0.6, endSpeed: end, mode: .play,
                       hands: .both, completed: completed)
        }
        XCTAssertEqual(progress.record(result(accuracy: 0.95, end: 0.6)), .up(to: 0.7))
        XCTAssertEqual(progress.level, 7)
        XCTAssertEqual(progress.bestStars, 3)
        XCTAssertEqual(progress.record(result(accuracy: 0.4, end: 0.65)), .down(to: 0.55))
        XCTAssertEqual(progress.record(result(accuracy: 0.8, end: 0.55)), .same)
        XCTAssertEqual(progress.gamesPlayed, 3)
        XCTAssertEqual(progress.history.count, 3)
        // Never beyond the limits.
        progress.speed = 1.2
        XCTAssertEqual(progress.record(result(accuracy: 1, end: 1.2)), .same)
        XCTAssertEqual(progress.speed, 1.2, accuracy: 1e-9)
    }

    func testDifficultyRanksDenseTwoHandedMusicHigher() {
        let easy = NoteChart(title: "easy", notes: (0..<16).map { ChartNote(id: 0, midi: 60 + $0 % 5, time: Double($0), duration: 1, hand: .right) },
                             beatsPerMinute: 60, source: .score)
        var hardNotes: [ChartNote] = []
        for i in 0..<64 {
            let t = Double(i) * 0.25
            hardNotes.append(ChartNote(id: 0, midi: 60 + (i * 7) % 24, time: t, duration: 0.25, hand: .right))
            if i % 2 == 0 {
                for m in [36, 43, 48] { hardNotes.append(ChartNote(id: 0, midi: m, time: t, duration: 0.5, hand: .left)) }
            }
        }
        let hard = NoteChart(title: "hard", notes: hardNotes, beatsPerMinute: 120, source: .score)
        let e = ChartDifficulty.estimate(easy), h = ChartDifficulty.estimate(hard)
        XCTAssertEqual(e.level, 1)
        XCTAssertEqual(h.level, 5)
        XCTAssertTrue(h.usesBothHands)
        XCTAssertEqual(h.largestChord, 4)
        // A beginner two-hand melody (like Ode to Joy with a bass note per bar) is level 2.
        XCTAssertEqual(ChartDifficulty.estimate(chart).level, 2)
    }
}

final class FeatureVectorPitchednessTests: XCTestCase {
    func testANoteWithOvertonesIsPitched() {
        XCTAssertTrue(FeatureVector.template(forPitches: [60]).isPitched)
        XCTAssertTrue(FeatureVector.template(forPitches: [60, 64]).isPitched)
    }

    func testWideBandNoiseIsNot() {
        var state: UInt32 = 7
        let noise = (0..<FeatureVector.semitoneCount).map { _ -> Float in
            state = state &* 1_664_525 &+ 1_013_904_223
            return 0.5 + Float(state >> 8) / Float(1 << 24)
        }
        XCTAssertFalse(FeatureVector(semitones: noise).isPitched)
        XCTAssertFalse(FeatureVector.zero.isPitched)
    }

    func testNoiseIsNotAWrongNote() {
        let chart = NoteChart(title: "t", notes: [ChartNote(id: 0, midi: 60, time: 0, duration: 1, hand: .right)],
                              beatsPerMinute: 60, source: .score)
        var configuration = GameConfiguration()
        configuration.mode = .learn
        let engine = GameEngine(chart: chart, configuration: configuration)
        engine.start(at: 0)
        engine.update(to: configuration.leadInSeconds + 0.1)
        var state: UInt32 = 3
        let noise = (0..<FeatureVector.semitoneCount).map { _ -> Float in
            state = state &* 1_664_525 &+ 1_013_904_223
            return 0.5 + Float(state >> 8) / Float(1 << 24)
        }
        engine.handle(NoteOnset(time: 0, strength: 1, levelDB: -20, features: FeatureVector(semitones: noise)),
                      at: configuration.leadInSeconds + 0.1)
        XCTAssertEqual(engine.stats.wrongNotes, 0)
        engine.handle(NoteOnset(time: 0, strength: 1, levelDB: -20, features: .template(forPitches: [72 + 7])),
                      at: configuration.leadInSeconds + 0.1)
        XCTAssertEqual(engine.stats.wrongNotes, 1, "a clear note that isn't the one asked for is wrong")
    }
}

final class PaceFollowerTests: XCTestCase {
    /// Chords one beat apart at 60 BPM (a second each at full speed), played every `interval` seconds.
    private func feed(_ follower: inout PaceFollower, intervals: [Double]) -> Double? {
        var clock = 0.0
        var result = follower.played(beat: 0, at: clock, secondsPerBeat: 1)
        for (i, interval) in intervals.enumerated() {
            clock += interval
            result = follower.played(beat: Double(i + 1), at: clock, secondsPerBeat: 1) ?? result
        }
        return result
    }

    func testFollowsTheMedianPaceDespiteOneHesitation() {
        var follower = PaceFollower()
        // Half speed (two seconds a beat), with one long hesitation.
        XCTAssertEqual(feed(&follower, intervals: [2, 2, 6, 2, 2]) ?? 0, 0.5, accuracy: 0.01)
    }

    func testNeedsTwoStretchesAndJoinsShortOnes() {
        var follower = PaceFollower()
        XCTAssertNil(follower.played(beat: 0, at: 0, secondsPerBeat: 1))
        XCTAssertNil(follower.played(beat: 1, at: 1.25, secondsPerBeat: 1))
        // A quarter of a beat is too short to measure alone: joined with the next one.
        XCTAssertNil(follower.played(beat: 1.25, at: 1.5, secondsPerBeat: 1))
        XCTAssertEqual(follower.played(beat: 2, at: 2.5, secondsPerBeat: 1) ?? 0, 0.8, accuracy: 0.01)
        XCTAssertEqual(follower.pace ?? 0, 0.8, accuracy: 0.01)
    }

    func testExcusedTimeAndStopsDontCount() {
        var follower = PaceFollower()
        _ = follower.played(beat: 0, at: 0, secondsPerBeat: 1)
        follower.excuse(0.5)
        _ = follower.played(beat: 1, at: 1.5, secondsPerBeat: 1)       // 1 s of playing: full speed
        follower.interrupt()                                            // stopped for a while
        _ = follower.played(beat: 2, at: 30, secondsPerBeat: 1)
        XCTAssertEqual(follower.played(beat: 3, at: 31, secondsPerBeat: 1) ?? 0, 1, accuracy: 0.01)
    }

    func testLeansSlowerWhileThePlayerIsBehind() {
        var follower = PaceFollower()
        var clock = 0.0
        var speed: Double?
        for beat in 0...4 {
            speed = follower.played(beat: Double(beat), at: clock, secondsPerBeat: 1, lateness: 0.25) ?? speed
            clock += 2
        }
        XCTAssertEqual(speed ?? 0, 0.45, accuracy: 0.01, "half speed, 10 % slower while a quarter second behind")
    }
}
