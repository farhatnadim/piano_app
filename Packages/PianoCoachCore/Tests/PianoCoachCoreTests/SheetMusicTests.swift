import XCTest
@testable import PianoCoachCore

final class SheetMusicTests: XCTestCase {
    private func chart(_ notes: [(midi: Int, time: Double, duration: Double, hand: Hand)], bars: [Double] = [0, 4, 8],
                       signature: TimeSignature = .common, key: Int = 0) -> NoteChart {
        NoteChart(title: "t", notes: notes.map { ChartNote(id: 0, midi: $0.midi, time: $0.time, duration: $0.duration, hand: $0.hand) },
                  beatsPerMinute: 100, barLines: bars, source: .score, keyFifths: key,
                  timeSignatures: bars.map { _ in signature })
    }

    private func written(_ sheet: SheetMusic, _ clef: SheetMusic.Clef) -> [String] {
        sheet.events.filter { $0.clef == clef }.map { e in
            let v = "\(e.value.base)\(e.value.dotted ? "." : "")"
            if e.isMeasureRest { return "M" }
            return e.isRest ? "r\(v)" : "\(e.heads.map(\.midi).map(String.init).joined(separator: "+")):\(v)\(e.tiedTo != nil ? "~" : "")"
        }
    }

    func testQuarterNotesAndRests() {
        let sheet = SheetMusic(chart: chart([(60, 0, 1, .right), (62, 1, 1, .right), (64, 3, 1, .right)], bars: [0]))
        XCTAssertEqual(written(sheet, .treble), ["60:4", "62:4", "r4", "64:4"])
        XCTAssertEqual(written(sheet, .bass), ["M"], "an empty measure gets a whole-measure rest")
        let twoBars = SheetMusic(chart: chart([(60, 0, 4, .right)], bars: [0, 4]))
        XCTAssertEqual(written(twoBars, .treble), ["60:1", "M"])
    }

    func testSlightlyEarlyEndsAreHeldToTheNextNote() {
        // A transcription: notes a little off the beat, ending early.
        let sheet = SheetMusic(chart: chart([(60, 0.02, 0.8, .right), (62, 0.98, 0.85, .right), (64, 2.01, 1.9, .right)], bars: [0]))
        XCTAssertEqual(written(sheet, .treble), ["60:4", "62:4", "64:2"])
        XCTAssertEqual(sheet.events.first?.beat ?? 0, 0.02, accuracy: 1e-9, "drawn at its own time")
    }

    func testExactShortNotesKeepTheirRests() {
        let sheet = SheetMusic(chart: chart([(60, 0, 0.5, .right), (62, 1, 0.5, .right), (64, 2, 2, .right)], bars: [0]))
        XCTAssertEqual(written(sheet, .treble), ["60:8", "r8", "62:8", "r8", "64:2"])
    }

    func testDottedValuesAndTiesAcrossTheBarLine() {
        let sheet = SheetMusic(chart: chart([(60, 0, 1.5, .right), (62, 1.5, 0.5, .right), (64, 2, 3, .right), (65, 5, 3, .right)],
                                            bars: [0, 4]))
        XCTAssertEqual(written(sheet, .treble), ["60:4.", "62:8", "64:2~", "64:4", "65:2."])
        let tied = sheet.events.first { $0.clef == .treble && $0.tiedTo != nil }!
        XCTAssertTrue(sheet.events[tied.tiedTo!].isTieContinuation)
    }

    func testThreeFourUsesDottedHalves() {
        let sheet = SheetMusic(chart: chart([(60, 0, 3, .right)], bars: [0], signature: TimeSignature(beats: 3, beatType: 4)))
        XCTAssertEqual(written(sheet, .treble), ["60:2."])
    }

    func testChordsHandsAndStems() {
        let sheet = SheetMusic(chart: chart([(43, 0, 4, .left), (48, 0, 4, .left), (72, 0, 1, .right), (74, 1, 1, .right),
                                             (76, 2, 2, .right)], bars: [0]))
        XCTAssertEqual(written(sheet, .bass), ["43+48:1"])
        XCTAssertEqual(written(sheet, .treble), ["72:4", "74:4", "76:2"])
        let high = sheet.events.first { $0.heads.first?.midi == 76 }!
        XCTAssertFalse(high.stemUp, "notes above the middle line have their stems down")
        let low = sheet.events.first { $0.heads.first?.midi == 43 }!
        XCTAssertTrue(low.stemUp)
    }

    func testEighthsAreBeamedByBeat() {
        let notes: [(Int, Double, Double, Hand)] = [(60, 0, 0.5, .right), (62, 0.5, 0.5, .right), (64, 1, 0.5, .right),
                                                    (65, 1.5, 0.25, .right), (67, 1.75, 0.25, .right), (69, 2, 2, .right)]
        let sheet = SheetMusic(chart: chart(notes.map { (midi: $0.0, time: $0.1, duration: $0.2, hand: $0.3) }, bars: [0]))
        XCTAssertEqual(written(sheet, .treble), ["60:8", "62:8", "64:8", "65:16", "67:16", "69:2"])
        XCTAssertEqual(sheet.beams.count, 2)
        XCTAssertEqual(sheet.beams.map(\.count), [2, 3])
    }

    func testAccidentalsFollowTheKeyAndTheMeasure() {
        // G major: F♯ needs no sign; F natural does; a second F♯ in the same measure needs a sharp again.
        let notes: [(Int, Double, Double, Hand)] = [(66, 0, 1, .right), (65, 1, 1, .right), (66, 2, 1, .right), (65, 4, 1, .right)]
        let sheet = SheetMusic(chart: chart(notes.map { (midi: $0.0, time: $0.1, duration: $0.2, hand: $0.3) }, bars: [0, 4], key: 1))
        let signs = sheet.events.filter { !$0.isRest }.map { $0.heads[0].accidental }
        XCTAssertEqual(signs, [nil, .natural, .sharp, .natural])
    }

    func testNoteValueSplitting() {
        let measure = SheetMusic.Measure(startBeat: 0, lengthBeats: 4, timeSignature: .common, showsTimeSignature: true)
        XCTAssertEqual(SheetMusic.values(from: 0, length: 4, in: measure), [.whole])
        XCTAssertEqual(SheetMusic.values(from: 0.5, length: 1.75, in: measure), [NoteValue(base: 4, dotted: true), .sixteenth])
        XCTAssertEqual(SheetMusic.values(from: 1, length: 3, in: measure), [NoteValue(base: 2, dotted: true)])
        XCTAssertEqual(SheetMusic.values(from: 0.25, length: 0.75, in: measure), [NoteValue(base: 8, dotted: true)])
        XCTAssertEqual(NoteValue.nearest(toBeats: 0.9), .quarter)
    }
}
