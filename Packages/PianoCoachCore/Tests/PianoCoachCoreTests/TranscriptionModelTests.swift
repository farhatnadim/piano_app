#if canImport(CoreML)
import CoreML
import XCTest
@testable import PianoCoachCore

/// Runs the app's Basic Pitch Core ML model end to end on piano sound — the app's own recorded piano,
/// played by `PianoSynthesizer` — so the model's inputs and outputs, the decoding and the arranging are
/// checked together on a real Apple runtime.
final class TranscriptionModelTests: XCTestCase {
    private static let repository: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }   // …/Tests/PianoCoachCoreTests/<file> -> repository root
        return url
    }()
    private static let packageURL = repository.appendingPathComponent("PianoCoach/Models/BasicPitchNMP.mlpackage")
    private static let pianoSamples = PianoSampleLoader.load(from: repository.appendingPathComponent("PianoCoach/PianoSamples"))

    private static let model: TranscriptionModel? = try? TranscriptionModel(packageAt: packageURL, computeUnits: .cpuOnly)

    private func loadModel() throws -> TranscriptionModel {
        try XCTUnwrap(Self.model, "Couldn't load \(Self.packageURL.path)")
    }

    func testModelShapes() throws {
        let model = try loadModel()
        let silence = [Float](repeating: 0, count: BasicPitch.windowSamples)
        let output = try model.run(window: silence)
        XCTAssertEqual(output.note.count, BasicPitch.framesPerWindow * 88)
        XCTAssertEqual(output.onset.count, BasicPitch.framesPerWindow * 88)
        XCTAssertTrue(output.note.allSatisfy(\.isFinite) && output.onset.allSatisfy(\.isFinite))
        // Pure digital silence can give high activations (0.9 has been seen); SongTranscriber guards against it.
        let dithered = try model.run(window: RecordingCleanup.prepare(silence, sampleRate: BasicPitch.sampleRate).samples)
        print(String(format: "Basic Pitch on silence: note max %.3f; with the noise floor: %.3f",
                     output.note.max() ?? 0, dithered.note.max() ?? 0))
    }

    func testSilenceGivesNoNotes() throws {
        let model = try loadModel()
        let seconds = 6.0
        let zeros = [Float](repeating: 0, count: Int(seconds * 48_000))
        XCTAssertEqual(try SongTranscriber.notes(inRecording: zeros, sampleRate: 48_000) { try model.run(window: $0) }, [])
        var state: UInt32 = 1
        let hiss = zeros.map { _ -> Float in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) - 0.5) * 2e-5
        }
        XCTAssertEqual(try SongTranscriber.notes(inRecording: hiss, sampleRate: 48_000) { try model.run(window: $0) }, [])
    }

    func testTranscribesMelodyAndBass() throws {
        let model = try loadModel()
        let truth = Self.odeToJoy(bpm: 100)
        let audio = Self.render(truth, sampleRate: BasicPitch.sampleRate)
        let started = Date()
        let notes = try BasicPitch.transcribe(samples: audio, runModel: { try model.run(window: $0) })
        let elapsed = Date().timeIntervalSince(started)
        let (precision, recall) = Self.score(found: notes, truth: truth)
        XCTAssertEqual(Self.pianoSamples.count, 88, "the recorded piano")
        print(String(format: "Basic Pitch on the recorded piano: %d notes found, %d expected, precision %.2f, recall %.2f, %.1f s for %.0f s of audio",
                     notes.count, truth.count, precision, recall, elapsed, Double(audio.count) / BasicPitch.sampleRate))
        XCTAssertGreaterThan(recall, 0.8)
        XCTAssertGreaterThan(precision, 0.7)

        let song = try XCTUnwrap(SongArranger.arrange(notes, title: "Ode to Joy"))
        print("Arranged: \(song.keyName), \(song.tempoBPM) BPM, \(song.score.notes.count) notes")
        XCTAssertEqual(song.keyFifths, 0, "C major")
        XCTAssertEqual(song.tempoBPM, 100, accuracy: 6)
        let right = song.score.notes.filter { $0.hand == .right }.count
        let left = song.score.notes.filter { $0.hand == .left }.count
        XCTAssertGreaterThan(right, left, "the melody is in the right hand")
        XCTAssertGreaterThan(left, 0, "the bass is in the left hand")
    }

    // MARK: - Helpers

    /// The first eight measures of Ode to Joy (quarter notes) over a bass note per half measure.
    private static func odeToJoy(bpm: Double) -> [TranscribedNote] {
        let beat = 60 / bpm
        let melody: [(Int, Double)] = [
            (64, 1), (64, 1), (65, 1), (67, 1), (67, 1), (65, 1), (64, 1), (62, 1),
            (60, 1), (60, 1), (62, 1), (64, 1), (64, 1.5), (62, 0.5), (62, 2),
            (64, 1), (64, 1), (65, 1), (67, 1), (67, 1), (65, 1), (64, 1), (62, 1),
            (60, 1), (60, 1), (62, 1), (64, 1), (62, 1.5), (60, 0.5), (60, 2),
        ]
        let bass = [48, 43, 48, 43, 48, 43, 48, 48]
        var notes: [TranscribedNote] = []
        var t = 0.5
        for (midi, beats) in melody {
            notes.append(TranscribedNote(midi: midi, start: t, end: t + beats * beat * 0.9, amplitude: 0.8))
            t += beats * beat
        }
        for (i, midi) in bass.enumerated() {
            for half in 0..<2 {
                let start = 0.5 + (Double(i) * 4 + Double(half) * 2) * beat
                notes.append(TranscribedNote(midi: midi, start: start, end: start + 2 * beat * 0.9, amplitude: 0.6))
            }
        }
        return notes.sorted { ($0.start, $0.midi) < ($1.start, $1.midi) }
    }

    /// Plays `notes` on the app's piano.
    private static func render(_ notes: [TranscribedNote], sampleRate: Double) -> [Float] {
        let synth = PianoSynthesizer(sampleRate: sampleRate)
        synth.loadSamples(pianoSamples)
        let end = (notes.map(\.end).max() ?? 0) + 1.5
        let total = Int(end * sampleRate)
        var events: [(sample: Int, on: Bool, note: TranscribedNote)] = []
        for note in notes {
            events.append((Int(note.start * sampleRate), true, note))
            events.append((Int(note.end * sampleRate), false, note))
        }
        events.sort { $0.sample < $1.sample }
        var audio = [Float](repeating: 0, count: total)
        var next = 0
        var position = 0
        let block = 64
        while position < total {
            while next < events.count, events[next].sample <= position {
                let event = events[next]
                if event.on {
                    synth.noteOn(event.note.midi, velocity: Float(event.note.amplitude))
                } else {
                    synth.noteOff(event.note.midi)
                }
                next += 1
            }
            let count = min(block, total - position)
            audio.withUnsafeMutableBufferPointer { buffer in
                synth.render(into: buffer.baseAddress! + position, frameCount: count)
            }
            position += count
        }
        return audio
    }

    /// Precision and recall of note onsets: same pitch, starting within 70 ms, each matched once.
    private static func score(found: [TranscribedNote], truth: [TranscribedNote]) -> (Double, Double) {
        var used = Set<Int>()
        var matched = 0
        for expected in truth {
            let candidate = found.indices.filter { !used.contains($0) && found[$0].midi == expected.midi
                && abs(found[$0].start - expected.start) < 0.07 }
                .min { abs(found[$0].start - expected.start) < abs(found[$1].start - expected.start) }
            if let candidate {
                used.insert(candidate)
                matched += 1
            }
        }
        let precision = found.isEmpty ? 0 : Double(matched) / Double(found.count)
        let recall = truth.isEmpty ? 0 : Double(matched) / Double(truth.count)
        return (precision, recall)
    }
}
#endif
