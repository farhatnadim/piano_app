import XCTest
@testable import PianoCoachCore

final class RecordingCleanupTests: XCTestCase {
    private let rate = 1_000.0

    func testTrimsSilentEndsAndKeepsAMargin() {
        // 2 s of zeros, 1 s of sound, 3 s of zeros.
        let samples = [Float](repeating: 0, count: 2_000) + [Float](repeating: 0.5, count: 1_000)
            + [Float](repeating: 0, count: 3_000)
        let (prepared, trimmed) = RecordingCleanup.prepare(samples, sampleRate: rate, margin: 0.25)
        XCTAssertEqual(trimmed, 1.75, accuracy: 1e-9)
        XCTAssertEqual(prepared.count, 250 + 1_000 + 250)
        XCTAssertEqual(prepared[300], 0.5, accuracy: 1e-4)
    }

    func testNoStretchIsExactlyZeroAndTheNoiseIsFaintAndRepeatable() {
        let silence = [Float](repeating: 0, count: 5_000)
        let (a, trimmed) = RecordingCleanup.prepare(silence, sampleRate: rate)
        let (b, _) = RecordingCleanup.prepare(silence, sampleRate: rate)
        XCTAssertEqual(trimmed, 0)
        XCTAssertEqual(a.count, silence.count, "all-silent recordings are kept whole")
        XCTAssertEqual(a, b)
        XCTAssertLessThanOrEqual(a.map(abs).max()!, 3e-5)
        XCTAssertGreaterThan(a.filter { $0 != 0 }.count, 4_900)
        XCTAssertEqual(RecordingCleanup.prepare([], sampleRate: rate).samples, [])
    }

    func testDropsNotesFoundInSilence() {
        // Sound only between 1 s and 2 s.
        var samples = [Float](repeating: 0.00001, count: 4_000)
        for i in 1_000..<2_000 { samples[i] = 0.4 }
        let notes = [
            TranscribedNote(midi: 60, start: 0.2, end: 0.8, amplitude: 0.9),   // in silence: phantom
            TranscribedNote(midi: 64, start: 1.1, end: 1.6, amplitude: 0.6),
            TranscribedNote(midi: 67, start: 1.95, end: 3.0, amplitude: 0.5),  // starts at the end of the sound
            TranscribedNote(midi: 72, start: 3.5, end: 3.9, amplitude: 0.7),   // in silence: phantom
        ]
        let kept = RecordingCleanup.droppingNotesInSilence(notes, samples: samples, sampleRate: rate)
        XCTAssertEqual(kept.map(\.midi), [64, 67])
        XCTAssertEqual(RecordingCleanup.droppingNotesInSilence(notes, samples: [Float](repeating: 0, count: 10),
                                                                sampleRate: rate), [])
        // A recording that is only faint hiss has no notes at all.
        let hiss = RecordingCleanup.prepare([Float](repeating: 0, count: 4_000), sampleRate: rate).samples
        XCTAssertEqual(RecordingCleanup.droppingNotesInSilence(notes, samples: hiss, sampleRate: rate), [])
    }
}
