import XCTest
@testable import PianoCoachCore

/// A drawn frame of a piano tutorial video: a keyboard at the bottom, keys lit in colour.
private struct DrawnFrame: VideoFrame {
    let width: Int
    let height: Int
    var pixels: [(Float, Float, Float)]

    func rgb(x: Int, y: Int) -> (r: Float, g: Float, b: Float) {
        let p = pixels[y * width + x]
        return (p.0, p.1, p.2)
    }

    /// `lowest`...`highest` white keys of `whiteWidth` pixels starting at x = `left`; keys in `lit` coloured.
    static func keyboard(width: Int = 1200, height: Int = 300, lowest: Int, highest: Int, whiteWidth: Int = 20,
                         left: Int = 30, lit: [Int: (Float, Float, Float)] = [:]) -> DrawnFrame {
        var pixels = [(Float, Float, Float)](repeating: (0.1, 0.1, 0.12), count: width * height)
        let top = 180, blackBottom = 245, bottom = 295
        var x = left
        var whiteX: [Int: Int] = [:]
        for midi in lowest...highest where !KeyboardVideoReader.isBlack(midi) {
            whiteX[midi] = x
            let color = lit[midi] ?? (0.97, 0.97, 0.97)
            for yy in top..<bottom { for xx in x..<(x + whiteWidth - 1) where xx < width { pixels[yy * width + xx] = color } }
            x += whiteWidth
        }
        for midi in lowest...highest where KeyboardVideoReader.isBlack(midi) {
            guard let right = whiteX[midi + 1] else { continue }
            let color = lit[midi] ?? (0.05, 0.05, 0.05)
            let w = whiteWidth * 6 / 10
            for yy in top..<blackBottom { for xx in (right - w / 2)..<(right + w / 2) where xx >= 0 && xx < width { pixels[yy * width + xx] = color } }
        }
        return DrawnFrame(width: width, height: height, pixels: pixels)
    }
}

final class KeyboardVideoReaderTests: XCTestCase {
    func testFindsAFullPianoAndNamesEveryKey() throws {
        let frame = DrawnFrame.keyboard(width: 1100, lowest: 21, highest: 108, whiteWidth: 20, left: 10)
        let layout = try XCTUnwrap(KeyboardVideoReader.findKeyboard(in: frame))
        XCTAssertEqual(layout.keys.filter(\.isBlack).count, 36)
        XCTAssertEqual(layout.keys.first?.midi, 21)
        XCTAssertEqual(layout.keys.last?.midi, 108)
        XCTAssertEqual(layout.keys.count, 88)
        let c4 = try XCTUnwrap(layout.keys.first { $0.midi == 60 })
        // C4 is the 24th white key (index 23) from A0.
        XCTAssertEqual(c4.x, 10 + 23 * 20 + 10, accuracy: 3)
    }

    func testFindsAPartialKeyboardCentredNearMiddleC() throws {
        let frame = DrawnFrame.keyboard(lowest: 48, highest: 84)
        let layout = try XCTUnwrap(KeyboardVideoReader.findKeyboard(in: frame))
        let midis = layout.keys.map(\.midi)
        XCTAssertEqual(midis.first.map { $0 % 12 }, 0, "starts on a C")
        XCTAssertEqual(midis.count, 37)
        XCTAssertEqual(midis, Array(midis.first!...midis.last!))
    }

    func testNoKeyboardInAPlainFrame() {
        let frame = DrawnFrame(width: 400, height: 200, pixels: Array(repeating: (0.5, 0.5, 0.5), count: 400 * 200))
        XCTAssertNil(KeyboardVideoReader.findKeyboard(in: frame))
    }

    func testReadsLitKeysAsNotes() throws {
        let reader = KeyboardVideoReader()
        var t = 0.0
        func show(_ lit: [Int: (Float, Float, Float)], frames: Int) {
            let frame = DrawnFrame.keyboard(lowest: 48, highest: 84, lit: lit)
            for _ in 0..<frames { reader.read(frame, at: t); t += 1.0 / 30 }
        }
        show([:], frames: 20)   // find and lock the keyboard
        let layout = try XCTUnwrap(reader.layout)
        let base = layout.keys.first!.midi   // a C
        let green: (Float, Float, Float) = (0.2, 0.85, 0.3)
        let blue: (Float, Float, Float) = (0.2, 0.4, 0.95)
        show([base + 4: green], frames: 10)                 // E
        show([:], frames: 3)
        show([base + 4: green, base + 1: blue], frames: 10) // E again, with C♯
        show([:], frames: 5)
        let notes = reader.notes()
        XCTAssertEqual(notes.count, 3)
        XCTAssertEqual(Set(notes.map(\.midi)), [base + 4, base + 1])
        XCTAssertEqual(notes[0].end - notes[0].start, 10.0 / 30, accuracy: 0.05)
        let sharp = try XCTUnwrap(notes.first { $0.midi == base + 1 })
        XCTAssertGreaterThan(sharp.hue, 0.5, "blue")
    }
}

final class VideoNoteAlignerTests: XCTestCase {
    func testFindsTheOctaveAndTheDelay() throws {
        let melody = [60, 62, 64, 65, 67, 65, 64, 62, 60, 64, 67, 72, 67, 64]
        let heard = melody.enumerated().map { i, m in
            TranscribedNote(midi: m, start: Double(i) * 0.5, end: Double(i) * 0.5 + 0.4, amplitude: 0.8)
        }
        // The video's keyboard was guessed an octave low, and its picture runs 0.2 s behind the sound.
        let video = melody.enumerated().map { i, m in
            KeyboardVideoReader.VideoNote(midi: m - 12, start: Double(i) * 0.5 + 0.2, end: Double(i) * 0.5 + 0.6, hue: 0.3)
        }
        let aligned = try XCTUnwrap(VideoNoteAligner.align(video: video, heard: heard))
        XCTAssertEqual(aligned.map(\.midi), melody)
        XCTAssertEqual(aligned[3].start, 1.5, accuracy: 0.03)
        XCTAssertEqual(aligned[0].amplitude, 0.8)
    }

    func testTooFewVideoNotes() {
        XCTAssertNil(VideoNoteAligner.align(video: [], heard: []))
    }
}
