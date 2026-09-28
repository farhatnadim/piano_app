import XCTest
@testable import PianoCoachCore

final class RateQuantizerTests: XCTestCase {
    private let q = RateQuantizer()

    func testDefaults() {
        XCTAssertEqual(RateQuantizer.youTubeStandardRates, [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
        XCTAssertEqual(q.rates, RateQuantizer.youTubeStandardRates)
    }

    func testRatesAreSortedAndUnique() {
        var r = RateQuantizer(rates: [1.5, 0.5, 1.0, 0.5, 1.0, -1, 0, .nan, .infinity])
        XCTAssertEqual(r.rates, [0.5, 1.0, 1.5])
        r.rates = [2, 1, 2, 0.75]
        XCTAssertEqual(r.rates, [0.75, 1, 2])
    }

    func testNearest() {
        XCTAssertEqual(q.nearest(to: 1.0), 1.0)
        XCTAssertEqual(q.nearest(to: 0.9), 1.0)
        XCTAssertEqual(q.nearest(to: 0.8), 0.75)
        XCTAssertEqual(q.nearest(to: 1.1), 1.0)
        XCTAssertEqual(q.nearest(to: 1.13), 1.25)
        XCTAssertEqual(q.nearest(to: 0.1), 0.25)
        XCTAssertEqual(q.nearest(to: 0), 0.25)
        XCTAssertEqual(q.nearest(to: -3), 0.25)
        XCTAssertEqual(q.nearest(to: 5), 2.0)
        XCTAssertEqual(q.nearest(to: .infinity), 2.0)
        XCTAssertEqual(q.nearest(to: .nan), 1.0)
    }

    func testNearestTieGoesSlower() {
        XCTAssertEqual(q.nearest(to: 0.625), 0.5)
        XCTAssertEqual(q.nearest(to: 0.875), 0.75)
        XCTAssertEqual(q.nearest(to: 1.125), 1.0)
    }

    func testNearestInRange() {
        XCTAssertEqual(q.nearest(to: 1.0, in: 0.5...0.9), 0.75)
        XCTAssertEqual(q.nearest(to: 0.3, in: 0.5...1.5), 0.5)
        XCTAssertEqual(q.nearest(to: 1.3, in: 0.5...1.5), 1.25)
        XCTAssertEqual(q.nearest(to: 1.9, in: 0.5...1.5), 1.5)
        XCTAssertEqual(q.nearest(to: 0.6, in: 0.5...1.0), 0.5)
        // No allowed rate inside the range: nearest allowed rate to the clamped value.
        XCTAssertEqual(q.nearest(to: 1.0, in: 0.8...0.85), 0.75)
        XCTAssertEqual(q.nearest(to: 0.2, in: 0.9...0.95), 1.0)
    }

    func testStep() {
        XCTAssertEqual(q.step(from: 1.0, by: -1), 0.75)
        XCTAssertEqual(q.step(from: 1.0, by: 1), 1.25)
        XCTAssertEqual(q.step(from: 1.0, by: -2), 0.5)
        XCTAssertEqual(q.step(from: 0.9, by: -1), 0.75)   // 0.9 snaps to 1.0 first
        XCTAssertEqual(q.step(from: 0.8, by: 1), 1.0)     // 0.8 snaps to 0.75 first
        XCTAssertEqual(q.step(from: 1.0, by: 0), 1.0)
        XCTAssertEqual(q.step(from: 0.9, by: 0), 1.0)
        XCTAssertEqual(q.step(from: 0.25, by: -1), 0.25)
        XCTAssertEqual(q.step(from: 2.0, by: 3), 2.0)
        XCTAssertEqual(q.step(from: 1.0, by: -100), 0.25)
        XCTAssertEqual(q.step(from: 1.0, by: Int.max), 2.0)
        XCTAssertEqual(q.step(from: 1.0, by: Int.min), 0.25)
    }

    func testFloor() {
        XCTAssertEqual(q.floor(1.0), 1.0)
        XCTAssertEqual(q.floor(0.99), 0.75)
        XCTAssertEqual(q.floor(1.3), 1.25)
        XCTAssertEqual(q.floor(3), 2.0)
        XCTAssertEqual(q.floor(0.1), 0.25)
        XCTAssertEqual(q.floor(0.75 - 1e-12), 0.75)   // floating-point noise tolerated
    }

    func testCustomAndEmptyRates() {
        let custom = RateQuantizer(rates: [0.5, 1.0])
        XCTAssertEqual(custom.nearest(to: 0.8), 1.0)
        XCTAssertEqual(custom.step(from: 0.5, by: 1), 1.0)
        let empty = RateQuantizer(rates: [])
        XCTAssertEqual(empty.nearest(to: 0.8), 0.8)
        XCTAssertEqual(empty.nearest(to: 0.8, in: 0.5...1), 0.8)
        XCTAssertEqual(empty.step(from: 0.8, by: 1), 0.8)
        XCTAssertEqual(empty.floor(0.8), 0.8)
    }
}
