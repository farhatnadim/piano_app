import XCTest
@testable import PianoCoachCore

/// Keeps the bundled sample in `Samples/` valid.
final class SampleScoreTests: XCTestCase {
    func testOdeToJoySampleParses() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Samples/Ode to Joy (easy).musicxml")
        let score = try ScoreLoader.loadScore(from: try Data(contentsOf: url), kind: .musicXML)
        XCTAssertEqual(score.title, "Ode to Joy (easy)")
        XCTAssertEqual(score.measures.count, 16)
        XCTAssertEqual(score.initialTempoBPM ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(score.totalBeats, 64, accuracy: 1e-9)
        XCTAssertEqual(score.events.first?.pitches, [48, 64])
        XCTAssertEqual(score.measure(numbered: 9)?.startBeat ?? -1, 32, accuracy: 1e-9)
    }
}
