import XCTest
@testable import PianoCoachCore

final class TapTempoTests: XCTestCase {

    func testNeedsTwoTaps() {
        var t = TapTempo()
        XCTAssertNil(t.bpm)
        XCTAssertNil(t.tap(at: 10))
        XCTAssertEqual(t.tapCount, 1)
        XCTAssertEqual(t.tap(at: 10.5)!, 120, accuracy: 1e-9)
        XCTAssertEqual(t.bpm!, 120, accuracy: 1e-9)
    }

    func testSteadyTaps() {
        var t = TapTempo()
        var result: Double?
        for i in 0..<6 { result = t.tap(at: 100 + Double(i) * 0.6) }
        XCTAssertEqual(result!, 100, accuracy: 1e-6)
    }

    func testMedianIgnoresOneBadTap() {
        var t = TapTempo()
        // Intervals: 0.5, 0.5, 0.9 (late tap), 0.1 (catch-up), 0.5, 0.5
        for time in [0, 0.5, 1.0, 1.9, 2.0, 2.5, 3.0] { t.tap(at: time) }
        XCTAssertEqual(t.bpm!, 120, accuracy: 1e-6)
    }

    func testEvenIntervalCountUsesMiddleAverage() {
        var t = TapTempo()
        // Intervals 0.4 and 0.6 -> median 0.5 -> 120 BPM.
        for time in [0, 0.4, 1.0] { t.tap(at: time) }
        XCTAssertEqual(t.bpm!, 120, accuracy: 1e-9)
    }

    func testLongGapRestarts() {
        var t = TapTempo(maxInterval: 2.0)
        t.tap(at: 0)
        t.tap(at: 1)          // 60 BPM
        XCTAssertEqual(t.bpm!, 60, accuracy: 1e-9)
        XCTAssertNil(t.tap(at: 3.5))  // 2.5 s gap: new measurement
        XCTAssertEqual(t.tapCount, 1)
        XCTAssertEqual(t.tap(at: 4.0)!, 120, accuracy: 1e-9)
    }

    func testGapExactlyMaxIntervalContinues() {
        var t = TapTempo(maxInterval: 2.0)
        t.tap(at: 0)
        XCTAssertEqual(t.tap(at: 2.0)!, 30, accuracy: 1e-9)
    }

    func testKeepsOnlyRecentTaps() {
        var t = TapTempo(maxTaps: 4)
        // Slow start (1 s intervals), then speeds up to 0.5 s intervals.
        for time in [0.0, 1.0, 2.0, 3.0, 3.5, 4.0, 4.5] { t.tap(at: time) }
        XCTAssertEqual(t.tapCount, 4)
        XCTAssertEqual(t.bpm!, 120, accuracy: 1e-9)
    }

    func testReset() {
        var t = TapTempo()
        t.tap(at: 0)
        t.tap(at: 0.5)
        t.reset()
        XCTAssertNil(t.bpm)
        XCTAssertEqual(t.tapCount, 0)
        XCTAssertNil(t.tap(at: 1))
    }

    func testDuplicateAndBackwardsTaps() {
        var t = TapTempo()
        t.tap(at: 1)
        XCTAssertNil(t.tap(at: 1))  // duplicate ignored
        XCTAssertEqual(t.tapCount, 1)
        t.tap(at: 1.5)
        XCTAssertNil(t.tap(at: 0.2))  // clock went backwards: restart
        XCTAssertEqual(t.tapCount, 1)
        XCTAssertNil(t.tap(at: .nan))
    }

    func testInvalidConfigurationIsSanitised() {
        let t = TapTempo(maxInterval: -1, maxTaps: 0)
        XCTAssertEqual(t.maxInterval, 2.0)
        XCTAssertEqual(t.maxTaps, 2)
    }
}
