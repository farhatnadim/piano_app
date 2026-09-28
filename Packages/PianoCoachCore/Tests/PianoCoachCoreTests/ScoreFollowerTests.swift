import XCTest
@testable import PianoCoachCore

final class ScoreFollowerTests: XCTestCase {
    // Video plays the score at 100 BPM starting 2 s in: one quarter = 0.6 s of video.
    let sync = SyncMap(bpm: 100, offset: 2)
    lazy var score = TestSupport.melodyScore()
    lazy var track = FollowTrack.fromScore(score, syncMap: sync)

    func testFollowsCleanPerformanceAndEstimatesHalfSpeed() {
        let follower = ScoreFollower(track: track)
        follower.reset(toVideoTime: 0)
        // The child plays at half speed: 1.2 s per quarter.
        var clock = 10.0
        for (i, e) in score.events.enumerated() {
            let state = follower.process(TestSupport.onset(e.pitches, at: clock, seed: i), at: clock)
            XCTAssertEqual(state.eventIndex, i, "event \(i)")
            clock += 1.2
        }
        XCTAssertEqual(follower.state.tempoRatio ?? 0, 0.5, accuracy: 0.05)
        XCTAssertEqual(follower.state.videoTime, sync.videoTime(forBeat: 31), accuracy: 1e-9)
    }

    func testRepeatedNotesAdvanceOneAtATime() {
        // Events 0 and 1 are both E4 (with bass on 0); 8 and 9 are both C4.
        let follower = ScoreFollower(track: track)
        follower.reset(toVideoTime: sync.videoTime(forBeat: 8))
        var clock = 0.0
        for i in 8...12 {
            let s = follower.process(TestSupport.onset(score.events[i].pitches, at: clock, seed: i), at: clock)
            XCTAssertEqual(s.eventIndex, i)
            clock += 0.6
        }
    }

    func testWrongNoteDoesNotAdvance() {
        let follower = ScoreFollower(track: track)
        follower.reset(toVideoTime: 0)
        var clock = 0.0
        for i in 0..<4 {
            follower.process(TestSupport.onset(score.events[i].pitches, at: clock, seed: i), at: clock)
            clock += 0.6
        }
        XCTAssertEqual(follower.state.eventIndex, 3)
        // A clearly wrong note (F#5 + C#2) is treated as noise.
        let s = follower.process(TestSupport.onset([78, 37], at: clock, seed: 99), at: clock)
        XCTAssertEqual(s.eventIndex, 3)
        XCTAssertFalse(follower.lastOnsetWasMatched)
        clock += 0.6
        // Then the right note continues.
        XCTAssertEqual(follower.process(TestSupport.onset(score.events[4].pitches, at: clock, seed: 4), at: clock).eventIndex, 4)
    }

    func testSkippedNoteIsHandled() {
        let follower = ScoreFollower(track: track)
        follower.reset(toVideoTime: 0)
        var clock = 0.0
        for i in [0, 1, 2, 3, 5, 6, 7] {   // skips event 4 (G4 + bass G2)
            follower.process(TestSupport.onset(score.events[i].pitches, at: clock, seed: i), at: clock)
            clock += 0.6
        }
        XCTAssertEqual(follower.state.eventIndex, 7)
    }

    func testRestartOfMeasureIsDetectedAsJump() {
        let follower = ScoreFollower(track: track)
        follower.reset(toVideoTime: 0)
        var clock = 0.0
        for i in 0..<11 {
            follower.process(TestSupport.onset(score.events[i].pitches, at: clock, seed: i), at: clock)
            clock += 0.6
        }
        XCTAssertEqual(follower.state.eventIndex, 10)
        // The child goes back to the start of measure 2 (event 4, which has a bass note) and plays on.
        var jumped = false
        for i in 4..<9 {
            let s = follower.process(TestSupport.onset(score.events[i].pitches, at: clock, seed: 100 + i), at: clock)
            jumped = jumped || s.jumped
            clock += 0.6
        }
        XCTAssertTrue(jumped)
        XCTAssertEqual(follower.state.eventIndex, 8)
    }

    func testEstimatedPositionNeverPassesNextUnplayedNote() {
        let follower = ScoreFollower(track: track)
        follower.reset(toVideoTime: 0)
        var clock = 0.0
        for i in 0..<5 {
            follower.process(TestSupport.onset(score.events[i].pitches, at: clock, seed: i), at: clock)
            clock += 0.6
        }
        let lastClock = clock - 0.6
        let current = track.events[4].videoTime
        let next = track.events[5].videoTime
        XCTAssertEqual(follower.estimatedVideoTime(at: lastClock), current, accuracy: 1e-6)
        XCTAssertGreaterThan(follower.estimatedVideoTime(at: lastClock + 0.3), current)
        XCTAssertLessThan(follower.estimatedVideoTime(at: lastClock + 30), next)
    }

    func testMIDIInputMatchesExactly() {
        let follower = ScoreFollower(track: track)
        follower.reset(toVideoTime: 0)
        var clock = 0.0
        for i in 0..<16 {
            let p = score.events[i].pitches
            let onset = NoteOnset(time: clock, strength: 1, levelDB: -20, features: .template(forPitches: p), midiPitches: p)
            XCTAssertEqual(follower.process(onset, at: clock).eventIndex, i)
            clock += 0.5
        }
    }

    func testRightHandOnlyStillFollows() {
        // The score has bass notes on downbeats; the child plays only the melody.
        let follower = ScoreFollower(track: track)
        follower.reset(toVideoTime: 0)
        var clock = 0.0
        let melodyOnly = score.events.map { Array($0.pitches.suffix(1)) }
        for i in 0..<16 {
            follower.process(TestSupport.onset(melodyOnly[i], at: clock, seed: i), at: clock)
            clock += 0.7
        }
        XCTAssertEqual(follower.state.eventIndex, 15)
    }

    func testResetToVideoTimeStartsFromThere() {
        let follower = ScoreFollower(track: track)
        follower.reset(toVideoTime: sync.videoTime(forBeat: 16))
        XCTAssertFalse(follower.state.hasStarted)
        let s = follower.process(TestSupport.onset(score.events[16].pitches, at: 1, seed: 1), at: 1)
        XCTAssertEqual(s.eventIndex, 16)
        XCTAssertTrue(s.hasStarted)
        XCTAssertFalse(s.jumped)
    }

    func testTempoRatioEstimatorIsRobustToOneHesitation() {
        var t = TempoRatioEstimator(smoothing: 1)
        var clock = 0.0
        var video = 0.0
        for i in 0..<8 {
            clock += i == 4 ? 1.5 : 0.5   // one hesitation
            video += 0.4
            t.add(clockTime: clock, videoTime: video)
        }
        XCTAssertEqual(t.ratio ?? 0, 0.8, accuracy: 0.05)
    }

    func testVideoClockExtrapolates() {
        var vc = VideoClock()
        XCTAssertNil(vc.videoTime(at: 0))
        vc.update(videoTime: 10, rate: 0.5, isPlaying: true, at: 100)
        vc.update(videoTime: 10.05, rate: 0.5, isPlaying: true, at: 100.1)
        XCTAssertEqual(vc.videoTime(at: 100.3) ?? 0, 10.15, accuracy: 1e-9)
        XCTAssertEqual(vc.videoTime(at: 100.05) ?? 0, 10.025, accuracy: 1e-9)
        vc.update(videoTime: 11, rate: 1, isPlaying: false, at: 101)
        XCTAssertEqual(vc.videoTime(at: 105) ?? 0, 11, accuracy: 1e-9)
    }

    func testTrackRecorderMergesAndFilters() {
        let rec = TrackRecorder(latency: 0.1, mergeWindow: 0.06)
        rec.add(TestSupport.onset([60], at: 0), videoTime: 1.1)
        rec.add(NoteOnset(time: 0, strength: 2, levelDB: -20, features: .template(forPitches: [64])), videoTime: 1.13)
        rec.add(TestSupport.onset([67], at: 0), videoTime: 2.1)
        rec.add(NoteOnset(time: 0, strength: 0.05, levelDB: -60, features: .template(forPitches: [70])), videoTime: 3.1)
        let track = rec.finish()
        XCTAssertEqual(track.events.count, 2)
        XCTAssertEqual(track.events[0].videoTime, 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(track.events[0].features.similarity(to: .template(forPitches: [64])), 0.99)
        XCTAssertEqual(track.origin, .learnedFromVideo)

        let replacement = FollowTrack(origin: .learnedFromVideo, events: [
            TrackEvent(index: 0, videoTime: 2.5, features: .template(forPitches: [72])),
        ])
        let merged = TrackRecorder.merge(base: track, with: replacement, replacing: 1.8...3.0)
        XCTAssertEqual(merged.events.map(\.videoTime), [1.0, 2.5])
    }
}
