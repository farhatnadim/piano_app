import XCTest
@testable import PianoCoachCore

/// End-to-end: synthesised audio -> OnsetAnalyzer -> ScoreFollower, for both kinds of reference track.
final class PipelineTests: XCTestCase {
    let sampleRate = 48_000.0
    lazy var score = TestSupport.melodyScore()

    /// Renders `events` of the score, one per `secondsPerBeat`, starting at `start`.
    private func render(events: ArraySlice<ScoreEvent>, secondsPerBeat: Double, start: Double,
                        length: Double, velocity: Float = 0.6, noise: Float = 0.002, seed: UInt64 = 7) -> [Float] {
        let first = events.first?.beat ?? 0
        var notes: [SynthPiano.Note] = []
        for e in events {
            for p in e.pitches {
                notes.append(.init(midi: p, start: start + (e.beat - first) * secondsPerBeat,
                                   duration: secondsPerBeat * 0.9, velocity: velocity))
            }
        }
        return SynthPiano.render(notes, sampleRate: sampleRate, length: length, noiseLevel: noise, seed: seed)
    }

    private func onsets(of audio: [Float]) -> [NoteOnset] {
        let analyzer = OnsetAnalyzer(sampleRate: sampleRate)
        var result: [NoteOnset] = []
        var i = 0
        while i < audio.count {
            let end = min(audio.count, i + 1024)
            result += analyzer.process(Array(audio[i..<end]))
            i = end
        }
        result += analyzer.process([Float](repeating: 0, count: Int(sampleRate * 0.3)))
        return result
    }

    func testFollowsSynthesisedChildAgainstScoreTrack() {
        let sync = SyncMap(bpm: 100, offset: 1)
        let track = FollowTrack.fromScore(score, syncMap: sync)
        let follower = ScoreFollower(track: track)
        follower.reset(toVideoTime: 0.5)

        // The child plays the first 16 events at 60 % speed (1.0 s per beat).
        let audio = render(events: score.events[0..<16], secondsPerBeat: 1.0, start: 0.5, length: 17.5)
        let heard = onsets(of: audio)
        XCTAssertEqual(heard.count, 16, "heard \(heard.map { $0.time })")
        var positions: [Int] = []
        for o in heard { positions.append(follower.process(o, at: o.time).eventIndex) }
        XCTAssertEqual(positions, Array(0..<16), "follower positions \(positions)")
        XCTAssertEqual(follower.state.tempoRatio ?? 0, 0.6, accuracy: 0.08)
    }

    func testLearnsTrackFromVideoAudioThenFollowsSlowerChild() {
        // 1) "Learn" pass: the video plays the whole melody at 100 BPM (0.6 s/beat), starting at 2 s.
        let videoAudio = render(events: score.events[0..<32], secondsPerBeat: 0.6, start: 2, length: 22,
                                velocity: 0.5, noise: 0.004, seed: 3)
        let recorder = TrackRecorder(latency: 0)
        for o in onsets(of: videoAudio) {
            // Video time equals audio time in this simulation (video started at clock 0, rate 1).
            recorder.add(o, videoTime: o.time)
        }
        let learned = recorder.finish()
        XCTAssertEqual(learned.events.count, 32, "learned \(learned.events.map { $0.videoTime })")
        for (e, s) in zip(learned.events, score.events) {
            XCTAssertEqual(e.videoTime, 2 + s.beat * 0.6, accuracy: 0.05)
        }

        // 2) The child plays measures 1-4 at ~57 % speed with a hesitation.
        let follower = ScoreFollower(track: learned, configuration: .learnedTrack)
        follower.reset(toVideoTime: 1.8)
        var childAudio = render(events: score.events[0..<8], secondsPerBeat: 1.05, start: 0.4, length: 9.5, seed: 11)
        childAudio += render(events: score.events[8..<16], secondsPerBeat: 1.05, start: 1.5, length: 10, seed: 12)
        let heard = onsets(of: childAudio)
        XCTAssertEqual(heard.count, 16, "heard \(heard.map { $0.time })")
        var positions: [Int] = []
        for o in heard { positions.append(follower.process(o, at: o.time).eventIndex) }
        XCTAssertEqual(positions, Array(0..<16), "follower positions \(positions)")
        XCTAssertEqual(follower.state.tempoRatio ?? 0, 0.6 / 1.05, accuracy: 0.1)
    }
}
