import XCTest
@testable import PianoCoachCore

/// Drives `PacingController` against a tiny simulated video player.
final class PacingControllerTests: XCTestCase {
    struct FakePlayer {
        var time = 0.0
        var playing = false
        var rate = 1.0
        var log: [PlayerCommand] = []

        mutating func apply(_ commands: [PlayerCommand]) {
            for c in commands {
                log.append(c)
                switch c {
                case .play: playing = true
                case .pause: playing = false
                case .setRate(let r): rate = r
                case .seek(let t): time = t
                }
            }
        }

        mutating func advance(_ dt: Double) {
            if playing { time += dt * rate }
        }
    }

    func testWaitForMeWaitsForFirstNotePausesOnSilenceAndResumes() {
        let pacing = PacingController()
        var player = FakePlayer(time: 5, playing: true)
        pacing.setMode(.waitForMe, now: 0)
        var lastOnset: Double? = nil
        var now = 0.0
        func tick() {
            let input = PacingInput(now: now, videoTime: player.time, videoIsPlaying: player.playing,
                                    currentRate: player.rate, lastOnsetClockTime: lastOnset)
            player.apply(pacing.update(input))
            player.advance(0.1)
            now += 0.1
        }
        tick()
        XCTAssertFalse(player.playing, "should pause until the child starts")
        XCTAssertEqual(pacing.status, .waitingToStart)
        for _ in 0..<10 { tick() }
        XCTAssertFalse(player.playing)

        // Child plays a note every 0.5 s for 3 s: video plays.
        for i in 0..<30 {
            if i % 5 == 0 { lastOnset = now }
            tick()
        }
        XCTAssertTrue(player.playing)
        // Child stops: video pauses after the silence timeout.
        for _ in 0..<35 { tick() }
        XCTAssertFalse(player.playing)
        XCTAssertEqual(pacing.status, .pausedForSilence)
        // Child plays again: video resumes.
        lastOnset = now
        tick()
        XCTAssertTrue(player.playing)
    }

    func testUserPauseIsRespected() {
        let pacing = PacingController()
        pacing.setMode(.waitForMe, now: 0)
        pacing.userDidPause(now: 1)
        let input = PacingInput(now: 2, videoTime: 0, videoIsPlaying: false, currentRate: 1, lastOnsetClockTime: 1.9)
        XCTAssertEqual(pacing.update(input), [])
        XCTAssertEqual(pacing.status, .pausedByUser)
        pacing.userDidPlay(now: 3)
        let after = pacing.update(PacingInput(now: 3.1, videoTime: 0, videoIsPlaying: false, currentRate: 1, lastOnsetClockTime: 1.9))
        XCTAssertEqual(after, [.play])
    }

    /// Full loop: follower + pacing + fake player with a child playing at 60 % speed.
    func testFollowMeSlowsDownAndNeverRunsAhead() {
        let sync = SyncMap(bpm: 100, offset: 2)      // 0.6 s of video per beat
        let score = TestSupport.melodyScore()
        let track = FollowTrack.fromScore(score, syncMap: sync)
        let follower = ScoreFollower(track: track)
        let pacing = PacingController()
        var player = FakePlayer(time: 1.8, playing: false)
        pacing.setMode(.followMe, now: 0)
        follower.reset(toVideoTime: player.time)

        let childSecondsPerBeat = 1.0                 // 60 % of the video's 0.6 s/beat
        let startClock = 1.0
        var now = 0.0
        var nextEvent = 0
        var lastOnset: Double?
        var maxLead = -Double.infinity
        var rates: Set<Double> = []
        while now < startClock + 30 * childSecondsPerBeat {
            // The child plays event n at startClock + n * childSecondsPerBeat.
            if nextEvent < 30, now >= startClock + Double(nextEvent) * childSecondsPerBeat {
                let e = score.events[nextEvent]
                follower.process(TestSupport.onset(e.pitches, at: now, seed: nextEvent), at: now)
                lastOnset = now
                nextEvent += 1
            }
            let child = follower.estimatedVideoTime(at: now)
            let input = PacingInput(now: now, videoTime: player.time, videoIsPlaying: player.playing,
                                    currentRate: player.rate, lastOnsetClockTime: lastOnset,
                                    follower: follower.state, childVideoTime: child,
                                    expectedGapSeconds: follower.expectedGapSeconds())
            player.apply(pacing.update(input))
            if follower.state.hasStarted, now > startClock + 3 {
                maxLead = max(maxLead, player.time - child)
                if player.playing { rates.insert(player.rate) }
            }
            player.advance(0.05)
            now += 0.05
        }
        XCTAssertLessThanOrEqual(maxLead, pacing.configuration.pauseLead + 0.15, "video ran ahead of the child")
        XCTAssertTrue(rates.contains { $0 < 1 }, "expected a slowed-down rate, got \(rates)")
        XCTAssertFalse(rates.contains { $0 > 1 }, "never faster than normal by default")
        // By the end the video is close to where the child is.
        let finalChild = follower.estimatedVideoTime(at: now)
        XCTAssertEqual(player.time, finalChild, accuracy: 1.5)
    }

    func testFollowMePausesWhenChildStopsAndSeeksWhenChildRestartsEarlier() {
        let sync = SyncMap(bpm: 120, offset: 0)       // 0.5 s per beat
        let score = TestSupport.melodyScore()
        let track = FollowTrack.fromScore(score, syncMap: sync)
        let follower = ScoreFollower(track: track)
        let pacing = PacingController()
        var player = FakePlayer(time: 0, playing: false)
        pacing.setMode(.followMe, now: 0)
        follower.reset(toVideoTime: 0)
        var now = 0.0
        var lastOnset: Double?
        func tick(_ seconds: Double) {
            let end = now + seconds
            while now < end {
                let input = PacingInput(now: now, videoTime: player.time, videoIsPlaying: player.playing,
                                        currentRate: player.rate, lastOnsetClockTime: lastOnset,
                                        follower: follower.state, childVideoTime: follower.estimatedVideoTime(at: now),
                                        expectedGapSeconds: follower.expectedGapSeconds())
                player.apply(pacing.update(input))
                player.advance(0.05)
                now += 0.05
            }
        }
        func play(_ i: Int) {
            follower.process(TestSupport.onset(score.events[i].pitches, at: now, seed: i), at: now)
            lastOnset = now
        }
        for i in 0..<12 { play(i); tick(0.5) }
        XCTAssertTrue(player.playing)
        tick(6)     // child stops
        XCTAssertFalse(player.playing)
        let pausedAt = player.time
        // The child's estimated position may advance up to (not past) their next note, beat 12.
        XCTAssertLessThanOrEqual(pausedAt, sync.videoTime(forBeat: 12) + pacing.configuration.pauseLead + 0.1)

        // Child goes back to measure 1 and plays on: the video should jump back near the start.
        for i in 0..<6 { play(i); tick(0.5) }
        XCTAssertLessThan(player.time, sync.videoTime(forBeat: 7))
        XCTAssertTrue(player.log.contains { if case .seek = $0 { return true } else { return false } })
    }

    func testQuantizedRateNeverAboveDesired() {
        let pacing = PacingController()
        XCTAssertEqual(pacing.quantizedRate(atMost: 0.6), 0.5)
        XCTAssertEqual(pacing.quantizedRate(atMost: 0.72), 0.75)   // within tolerance
        XCTAssertEqual(pacing.quantizedRate(atMost: 0.1), 0.25)
        XCTAssertEqual(pacing.quantizedRate(atMost: 1.6), 1.0)     // capped by maxRate
    }

    /// The video is parked well past the child, who starts playing ~7 s earlier in the piece:
    /// the video must come back to them rather than wait forever.
    func testFollowMeRewindsWhenChildStartsFarBehindTheVideo() {
        let sync = SyncMap(bpm: 120, offset: 0)          // 0.5 s per beat
        let score = TestSupport.melodyScore()
        let track = FollowTrack.fromScore(score, syncMap: sync)
        let follower = ScoreFollower(track: track)
        let pacing = PacingController()
        var player = FakePlayer(time: sync.videoTime(forBeat: 30), playing: false)
        pacing.setMode(.followMe, now: 0)
        follower.reset(toVideoTime: player.time)
        var now = 0.0
        var lastOnset: Double?
        for i in 16..<24 {
            follower.process(TestSupport.onset(score.events[i].pitches, at: now, seed: i), at: now)
            lastOnset = now
            for _ in 0..<10 {
                let input = PacingInput(now: now, videoTime: player.time, videoIsPlaying: player.playing,
                                        currentRate: player.rate, lastOnsetClockTime: lastOnset,
                                        follower: follower.state, childVideoTime: follower.estimatedVideoTime(at: now),
                                        expectedGapSeconds: follower.expectedGapSeconds())
                player.apply(pacing.update(input))
                player.advance(0.05)
                now += 0.05
            }
        }
        XCTAssertEqual(follower.state.eventIndex, 23)
        XCTAssertTrue(player.log.contains { if case .seek = $0 { return true } else { return false } })
        XCTAssertEqual(player.time, follower.estimatedVideoTime(at: now), accuracy: 1.2)
        XCTAssertTrue(player.playing)
    }
}
