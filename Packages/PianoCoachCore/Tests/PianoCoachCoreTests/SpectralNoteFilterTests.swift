import XCTest
@testable import PianoCoachCore

final class SpectralNoteFilterTests: XCTestCase {
    private let rate = 22_050.0

    /// A decaying tone with a few overtones, like a plucked or struck string.
    private func tone(midi: Int, from start: Double, to end: Double, level: Float, into audio: inout [Float]) {
        let hz = SpectralNoteFilter.frequency(ofMIDI: midi)
        let first = Int(start * rate), last = min(audio.count, Int(end * rate))
        guard first < last else { return }
        for i in first..<last {
            let t = Double(i - first) / rate
            let decay = Float(exp(-t * 1.5))
            var s: Float = 0
            for h in 1...4 { s += Float(sin(2 * .pi * hz * Double(h) * t)) / Float(h) }
            audio[i] += s * level * decay
        }
    }

    private func note(_ midi: Int, _ start: Double, _ end: Double, _ amplitude: Double) -> TranscribedNote {
        TranscribedNote(midi: midi, start: start, end: end, amplitude: amplitude)
    }

    func testKeepsNotesTheSoundContains() {
        var audio = [Float](repeating: 0, count: Int(3 * rate))
        tone(midi: 60, from: 0.2, to: 1.2, level: 0.3, into: &audio)
        tone(midi: 67, from: 1.2, to: 2.2, level: 0.3, into: &audio)
        let notes = [note(60, 0.2, 1.2, 0.7), note(67, 1.2, 2.2, 0.7)]
        XCTAssertEqual(SpectralNoteFilter.supportedNotes(notes, samples: audio, sampleRate: rate), notes)
    }

    func testDropsNotesWithNoPeakInTheSpectrum() {
        var audio = [Float](repeating: 0, count: Int(3 * rate))
        tone(midi: 60, from: 0.2, to: 1.2, level: 0.3, into: &audio)
        let notes = [note(60, 0.2, 1.2, 0.7), note(66, 0.2, 0.6, 0.4), note(61, 1.6, 2.0, 0.5)]
        XCTAssertEqual(SpectralNoteFilter.supportedNotes(notes, samples: audio, sampleRate: rate), [notes[0]])
    }

    func testDropsOvertoneGhostsButKeepsRealOctaves() {
        var audio = [Float](repeating: 0, count: Int(4 * rate))
        tone(midi: 48, from: 0.2, to: 1.2, level: 0.3, into: &audio)   // C3 alone: its overtones ring at C4, G4
        tone(midi: 48, from: 2.0, to: 3.0, level: 0.3, into: &audio)   // C3 with a real C4 on top
        tone(midi: 60, from: 2.0, to: 3.0, level: 0.3, into: &audio)
        let notes = [note(48, 0.2, 1.2, 0.8), note(60, 0.2, 0.7, 0.35), note(67, 0.21, 0.5, 0.3),
                     note(48, 2.0, 3.0, 0.8), note(60, 2.0, 3.0, 0.4)]
        XCTAssertEqual(SpectralNoteFilter.supportedNotes(notes, samples: audio, sampleRate: rate),
                       [notes[0], notes[3], notes[4]])
    }

    func testDropsFaintPhantomAnOctaveBelowARingingNote() {
        var audio = [Float](repeating: 0, count: Int(2 * rate))
        tone(midi: 60, from: 0.2, to: 1.8, level: 0.3, into: &audio)
        let notes = [note(60, 0.2, 1.8, 0.8), note(48, 0.5, 0.8, 0.3)]
        XCTAssertEqual(SpectralNoteFilter.supportedNotes(notes, samples: audio, sampleRate: rate), [notes[0]])
    }

    func testEmptyInputs() {
        XCTAssertEqual(SpectralNoteFilter.supportedNotes([], samples: [1, 2], sampleRate: rate), [])
        let notes = [note(60, 0, 1, 0.5)]
        XCTAssertEqual(SpectralNoteFilter.supportedNotes(notes, samples: [], sampleRate: rate), notes)
        XCTAssertEqual(SpectralNoteFilter.supportedNotes(notes, samples: [0, 0, 0], sampleRate: rate), [])
    }
}
