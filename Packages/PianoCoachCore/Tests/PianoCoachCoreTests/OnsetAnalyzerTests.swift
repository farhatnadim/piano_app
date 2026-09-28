import XCTest
@testable import PianoCoachCore

final class OnsetAnalyzerTests: XCTestCase {
    private func analyze(_ samples: [Float], sampleRate: Double, sensitivity: Float = 0.5, chunk: Int = 1024) -> [NoteOnset] {
        let analyzer = OnsetAnalyzer(sampleRate: sampleRate, sensitivity: sensitivity)
        var onsets: [NoteOnset] = []
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + chunk)
            onsets += analyzer.process(Array(samples[i..<end]))
            i = end
        }
        // Flush pending features with a little silence.
        onsets += analyzer.process([Float](repeating: 0, count: Int(sampleRate * 0.3)))
        return onsets
    }

    func testFFTFindsSinePeak() {
        let fft = RealFFT(size: 1024)
        let sr = 48_000.0
        let bin = 40
        let f = Double(bin) * sr / 1024
        let x = (0..<1024).map { Float(sin(2 * Double.pi * f * Double($0) / sr)) }
        let mags = fft.magnitudes(x)
        XCTAssertEqual(mags.count, 513)
        let peak = mags.indices.max { mags[$0] < mags[$1] }
        XCTAssertEqual(peak, bin)
        XCTAssertEqual(mags[bin], 1, accuracy: 0.05)
    }

    func testDetectsEachNoteOfAScaleWithTiming() {
        let sr = 48_000.0
        let midis = [60, 62, 64, 65, 67, 69, 71, 72]
        let notes = midis.enumerated().map { i, m in SynthPiano.Note(midi: m, start: 0.5 + Double(i) * 0.5, duration: 0.45) }
        let audio = SynthPiano.render(notes, sampleRate: sr, length: 5, noiseLevel: 0.001)
        let onsets = analyze(audio, sampleRate: sr)
        XCTAssertEqual(onsets.count, notes.count, "onset times: \(onsets.map { $0.time })")
        for (onset, note) in zip(onsets, notes) {
            XCTAssertEqual(onset.time, note.start, accuracy: 0.04)
            // The strongest key in the features should be the played note (or its octave).
            let best = onset.features.semitones.indices.max { onset.features.semitones[$0] < onset.features.semitones[$1] }!
            let bestMidi = best + Pitch.lowestPianoMIDI
            XCTAssertEqual(Pitch.pitchClass(bestMidi), Pitch.pitchClass(note.midi), "note \(note.midi) got \(bestMidi)")
        }
    }

    func testFeaturesMatchTemplateOfPlayedChordBetterThanNeighbours() {
        let sr = 44_100.0
        let chords: [[Int]] = [[48, 60, 64, 67], [53, 60, 65, 69], [55, 59, 62, 67], [48, 60, 64, 67]]
        var notes: [SynthPiano.Note] = []
        for (i, c) in chords.enumerated() {
            for m in c { notes.append(.init(midi: m, start: 0.4 + Double(i) * 0.8, duration: 0.7)) }
        }
        let audio = SynthPiano.render(notes, sampleRate: sr, length: 4, noiseLevel: 0.001)
        let onsets = analyze(audio, sampleRate: sr)
        XCTAssertEqual(onsets.count, chords.count, "onset times: \(onsets.map { $0.time })")
        let templates = chords.map { FeatureVector.template(forPitches: $0) }
        for (i, onset) in onsets.enumerated() where i < chords.count {
            let sims = templates.map { onset.features.similarity(to: $0) }
            let own = sims[i]
            for (j, s) in sims.enumerated() where chords[j] != chords[i] {
                XCTAssertGreaterThan(own, s, "chord \(i) sims \(sims)")
            }
            XCTAssertGreaterThan(own, 0.6, "chord \(i) sims \(sims)")
        }
    }

    func testRepeatedNoteIsDetectedEveryTime() {
        let sr = 48_000.0
        let notes = (0..<6).map { SynthPiano.Note(midi: 67, start: 0.3 + Double($0) * 0.35, duration: 0.3) }
        let audio = SynthPiano.render(notes, sampleRate: sr, length: 3, noiseLevel: 0.001)
        let onsets = analyze(audio, sampleRate: sr)
        XCTAssertEqual(onsets.count, 6, "onset times: \(onsets.map { $0.time })")
    }

    func testSustainedChordWithMelodyAbove() {
        // Left hand holds a chord while the right hand plays a melody: every melody note is an onset.
        let sr = 48_000.0
        var notes = [SynthPiano.Note(midi: 48, start: 0.3, duration: 2.4), .init(midi: 55, start: 0.3, duration: 2.4)]
        let melody = [72, 74, 76, 77, 79]
        for (i, m) in melody.enumerated() { notes.append(.init(midi: m, start: 0.3 + Double(i) * 0.5, duration: 0.45, velocity: 0.6)) }
        let audio = SynthPiano.render(notes, sampleRate: sr, length: 3.5, noiseLevel: 0.001)
        let onsets = analyze(audio, sampleRate: sr)
        XCTAssertEqual(onsets.count, melody.count, "onset times: \(onsets.map { $0.time })")
        // Later melody notes should look like the melody note, not the held chord.
        for (i, onset) in onsets.enumerated().dropFirst() where i < melody.count {
            let own = onset.features.similarity(to: .template(forPitches: [melody[i]]))
            let chord = onset.features.similarity(to: .template(forPitches: [48, 55]))
            XCTAssertGreaterThan(own, chord, "melody note \(melody[i])")
        }
    }

    func testSilenceAndNoiseProduceNoOnsets() {
        let sr = 48_000.0
        let quiet = SynthPiano.render([], sampleRate: sr, length: 3, noiseLevel: 0.01)
        XCTAssertTrue(analyze(quiet, sampleRate: sr).isEmpty)
    }

    func testChunkSizeDoesNotChangeResults() {
        let sr = 48_000.0
        let notes = [60, 64, 67].enumerated().map { SynthPiano.Note(midi: $1, start: 0.3 + Double($0) * 0.4, duration: 0.35) }
        let audio = SynthPiano.render(notes, sampleRate: sr, length: 2, noiseLevel: 0.001)
        let a = analyze(audio, sampleRate: sr, chunk: 4800).map { $0.time }
        let b = analyze(audio, sampleRate: sr, chunk: 333).map { $0.time }
        XCTAssertEqual(a.count, b.count)
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 1e-9) }
    }

    func testMIDIGrouperMergesChord() {
        var g = MIDINoteGrouper(window: 0.03)
        XCTAssertNil(g.noteOn(midi: 60, velocity: 80, time: 1.0))
        XCTAssertNil(g.noteOn(midi: 64, velocity: 90, time: 1.01))
        XCTAssertNil(g.noteOn(midi: 67, velocity: 70, time: 1.02))
        XCTAssertNil(g.flush(now: 1.02))
        let chord = g.noteOn(midi: 72, velocity: 60, time: 1.5)
        XCTAssertEqual(chord?.midiPitches, [60, 64, 67])
        XCTAssertEqual(chord?.time ?? 0, 1.0, accuracy: 1e-9)
        let single = g.flush(now: 1.6)
        XCTAssertEqual(single?.midiPitches, [72])
        XCTAssertNil(g.flush(now: 2.0))
    }
}
