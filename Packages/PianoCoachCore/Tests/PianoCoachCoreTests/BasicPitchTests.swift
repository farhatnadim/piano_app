import XCTest
@testable import PianoCoachCore

/// Checks the Basic Pitch port against fixtures produced by the Python reference (basic-pitch 0.4.0 with its ONNX
/// model) on synthetic piano clips and on random matrices.
final class BasicPitchTests: XCTestCase {
    // MARK: - Windowing and stitching

    func testConstants() {
        XCTAssertEqual(BasicPitch.hopSamples, 36164)
        XCTAssertEqual(BasicPitch.keptFramesPerWindow, 142)
        XCTAssertEqual(BasicPitch.leadingPadding, 3840)
        XCTAssertEqual(BasicPitch.frameCount(forSampleCount: 70560), 275)
        XCTAssertEqual(BasicPitch.frameCount(forSampleCount: 256), 0)
        XCTAssertEqual(BasicPitch.frameCount(forSampleCount: 257), 1)
    }

    func testWindowPaddingMatchesReference() throws {
        for testCase in try referenceFixture().stitchCases {
            let windows = BasicPitch.windows(for: [Float](repeating: 1, count: testCase.sampleCount))
            XCTAssertEqual(windows.count, testCase.windows.count, "samples: \(testCase.sampleCount)")
            XCTAssertEqual(BasicPitch.windowCount(forSampleCount: testCase.sampleCount), testCase.windows.count)
            for (window, expected) in zip(windows, testCase.windows) {
                XCTAssertEqual(window.count, BasicPitch.windowSamples)
                let ones = window.indices.filter { window[$0] != 0 }
                XCTAssertEqual([ones.first ?? -1, ones.last ?? -1, ones.count], expected,
                               "samples: \(testCase.sampleCount)")
            }
        }
    }

    func testStitchSelectsTheSameRowsAsReference() throws {
        for testCase in try referenceFixture().stitchCases {
            let outputs = (0..<testCase.windows.count).map { w in
                (0..<BasicPitch.framesPerWindow).flatMap { j in [Float(w), Float(j)] }
            }
            let stitched = BasicPitch.stitch(outputs, width: 2, originalSampleCount: testCase.sampleCount)
            XCTAssertEqual(stitched.count, testCase.frameCount * 2)
            XCTAssertEqual(BasicPitch.frameCount(forSampleCount: testCase.sampleCount), testCase.frameCount)
            var runs: [[Int]] = []
            for row in 0..<(stitched.count / 2) {
                let w = Int(stitched[2 * row]), j = Int(stitched[2 * row + 1])
                if let last = runs.last, last[0] == w, last[1] + last[2] == j {
                    runs[runs.count - 1][2] += 1
                } else {
                    runs.append([w, j, 1])
                }
            }
            XCTAssertEqual(runs, testCase.rowRuns, "samples: \(testCase.sampleCount)")
        }
    }

    func testFixtureAudioWindowsMatchReference() throws {
        let clip = try clipFixture("long_melody")
        let audio = try clipAudio(clip)
        XCTAssertEqual(audio.count, clip.sampleCount)
        let windows = BasicPitch.windows(for: audio)
        XCTAssertEqual(windows.count, clip.windowCount)
        XCTAssertEqual(windows.map { String(checksum($0)) }, clip.windowChecksums)
    }

    func testStitchedModelOutputsMatchReference() throws {
        for name in try referenceFixture().clips {
            let clip = try clipFixture(name)
            let outputs = try clipOutputs(clip)
            XCTAssertEqual(outputs.note.count, clip.windowCount)
            let note = BasicPitch.stitch(outputs.note, width: 88, originalSampleCount: clip.sampleCount)
            let onset = BasicPitch.stitch(outputs.onset, width: 88, originalSampleCount: clip.sampleCount)
            XCTAssertEqual(note.count, clip.frameCount * 88, name)
            XCTAssertEqual(String(checksum(note)), clip.stitchedChecksums["note"], name)
            XCTAssertEqual(String(checksum(onset)), clip.stitchedChecksums["onset"], name)
        }
    }

    // MARK: - Note decoding against the reference

    func testFrameTimesMatchReference() throws {
        let reference = try referenceFixture().frameTimes
        for (frame, time) in reference.times.enumerated() {
            XCTAssertEqual(BasicPitch.time(ofFrame: frame), time, accuracy: 1e-12, "frame \(frame)")
        }
    }

    func testMinimumNoteFramesMatchesReference() throws {
        for (ms, frames) in try referenceFixture().minimumNoteFrames {
            XCTAssertEqual(BasicPitch.DecoderSettings(minimumNoteLengthMs: Double(ms)!).minimumNoteFrames, frames)
        }
        XCTAssertEqual(BasicPitch.DecoderSettings().minimumNoteFrames, 11)
    }

    func testNotesMatchReferenceOnModelOutputs() throws {
        for name in try referenceFixture().clips {
            let clip = try clipFixture(name)
            let outputs = try clipOutputs(clip)
            let note = BasicPitch.stitch(outputs.note, width: 88, originalSampleCount: clip.sampleCount)
            let onset = BasicPitch.stitch(outputs.onset, width: 88, originalSampleCount: clip.sampleCount)
            for (label, variant) in clip.variants.sorted(by: { $0.key < $1.key }) {
                let settings = variant.settings.decoderSettings
                XCTAssertEqual(settings.minimumNoteFrames, variant.settings.minimumNoteFrames)
                let found = BasicPitch.frameNotes(frames: note, onsets: onset, frameCount: clip.frameCount,
                                                  settings: settings)
                assertMatches(found, variant.notes, "\(name) \(label)")
                let timed = BasicPitch.notes(frames: note, onsets: onset, frameCount: clip.frameCount,
                                             settings: settings)
                XCTAssertEqual(timed.count, variant.notes.count)
                for (got, row) in zip(timed, variant.notes) {
                    XCTAssertEqual(got.midi, Int(row[2]))
                    XCTAssertEqual(got.start, row[4], accuracy: 1e-6, "\(name) \(label)")
                    XCTAssertEqual(got.end, row[5], accuracy: 1e-6, "\(name) \(label)")
                    XCTAssertEqual(got.amplitude, row[3], accuracy: 1e-5, "\(name) \(label)")
                }
            }
        }
    }

    func testNotesMatchReferenceOnRandomMatrices() throws {
        let fixture: RandomFixture = try decodeJSON("random.json")
        let codes = try [UInt8](Inflate.inflate(Data(contentsOf: fixtureURL("random.bin"))))
        for testCase in fixture.cases {
            let size = testCase.frameCount * 88
            let decode = { (start: Int) in codes[start..<(start + size)].map { Float($0) / Float(fixture.divisor) } }
            let frames = decode(testCase.offset)
            let onsets = decode(testCase.offset + size)
            for (label, variant) in testCase.variants.sorted(by: { $0.key < $1.key }) {
                let found = BasicPitch.frameNotes(frames: frames, onsets: onsets, frameCount: testCase.frameCount,
                                                  settings: variant.settings.decoderSettings)
                assertMatches(found, variant.notes, "\(testCase.name) \(label)")
            }
        }
    }

    func testTranscribeMatchesReferenceEndToEnd() throws {
        let clip = try clipFixture("long_melody")
        let audio = try clipAudio(clip)
        let outputs = try clipOutputs(clip)
        var calls = 0
        var progress: [Double] = []
        let notes = BasicPitch.transcribe(samples: audio, progress: { progress.append($0) }) { window in
            XCTAssertEqual(String(checksum(window)), clip.windowChecksums[calls], "window \(calls)")
            defer { calls += 1 }
            return (outputs.note[calls], outputs.onset[calls])
        }
        // The fifth window only covers frames that are trimmed away, so it is never run.
        XCTAssertEqual(calls, (clip.frameCount + 141) / 142)
        XCTAssertEqual(progress, (1...calls).map { Double($0) / Double(calls) })
        let expected = clip.variants["default"]!.notes
        XCTAssertEqual(notes.count, expected.count)
        for (got, row) in zip(notes, expected) {
            XCTAssertEqual(got.midi, Int(row[2]))
            XCTAssertEqual(got.start, row[4], accuracy: 1e-6)
            XCTAssertEqual(got.end, row[5], accuracy: 1e-6)
            XCTAssertEqual(got.amplitude, row[3], accuracy: 1e-5)
        }
    }

    // MARK: - Edge cases

    func testEmptyAndShortAudio() {
        XCTAssertEqual(BasicPitch.windows(for: []), [[Float](repeating: 0, count: BasicPitch.windowSamples)])
        var calls = 0
        let silentModel = { (_: [Float]) -> (note: [Float], onset: [Float]) in
            calls += 1
            return ([Float](repeating: 0, count: 172 * 88), [Float](repeating: 0, count: 172 * 88))
        }
        var progress: [Double] = []
        XCTAssertEqual(BasicPitch.transcribe(samples: [], progress: { progress.append($0) }, runModel: silentModel), [])
        XCTAssertEqual(BasicPitch.transcribe(samples: [Float](repeating: 0.1, count: 256), runModel: silentModel), [])
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(progress, [1])

        let short = (0..<5000).map { Float(sin(Double($0) * 0.1)) }
        XCTAssertEqual(BasicPitch.windows(for: short).count, 1)
        XCTAssertEqual(BasicPitch.transcribe(samples: short, runModel: silentModel), [])
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(BasicPitch.stitch([], width: 88, originalSampleCount: 5000), [])
        XCTAssertEqual(BasicPitch.notes(frames: [], onsets: [], frameCount: 0), [])
    }

    func testAllZeroOrFlatOutputsGiveNoNotes() {
        let n = 400
        let zeros = [Float](repeating: 0, count: n * 88)
        let flat = [Float](repeating: 0.2, count: n * 88)
        for settings in [BasicPitch.DecoderSettings(), .init(inferOnsets: false), .init(melodiaTrick: false),
                         .init(onsetThreshold: 0.1, frameThreshold: 0.1)] {
            XCTAssertEqual(BasicPitch.notes(frames: zeros, onsets: zeros, frameCount: n, settings: settings), [])
            // Flat onsets have no peaks; flat frames below the frame threshold give the melodia step nothing.
            let expectMelodia = settings.melodiaTrick && settings.frameThreshold < 0.2
            let flatNotes = BasicPitch.notes(frames: flat, onsets: flat, frameCount: n, settings: settings)
            XCTAssertEqual(flatNotes.isEmpty, !expectMelodia)
        }
    }

    func testThresholdsAndLimitsAreRespected() {
        // One clean middle C: activation 0.8 in frames 50..<90 and an onset peak at frame 50.
        let n = 200, bin = 60 - 21
        var frames = [Float](repeating: 0.05, count: n * 88)
        var onsets = [Float](repeating: 0.02, count: n * 88)
        for t in 50..<90 { frames[t * 88 + bin] = 0.8 }
        onsets[50 * 88 + bin] = 0.9
        func decode(_ settings: BasicPitch.DecoderSettings) -> [BasicPitch.FrameNote] {
            BasicPitch.frameNotes(frames: frames, onsets: onsets, frameCount: n, settings: settings)
        }
        let note = BasicPitch.FrameNote(startFrame: 50, endFrame: 90, midi: 60, amplitude: Double(Float(0.8)))
        XCTAssertEqual(decode(.init()), [note])
        XCTAssertEqual(decode(.init(onsetThreshold: 0.95, melodiaTrick: false)), [])
        // Found by the melodia step instead, which (like the reference) ends one frame earlier.
        let melodia = decode(.init(onsetThreshold: 0.95))
        XCTAssertEqual(melodia.map { [$0.startFrame, $0.endFrame, $0.midi] }, [[50, 89, 60]])
        XCTAssertEqual(decode(.init(frameThreshold: 0.85)), [])
        XCTAssertEqual(decode(.init(minimumNoteLengthMs: 500)), [])
        XCTAssertEqual(decode(.init(minimumNoteLengthMs: 400)), [note])
        XCTAssertEqual(decode(.init(maximumFrequency: 200)), [])
        XCTAssertEqual(decode(.init(minimumFrequency: 300)), [])
        XCTAssertEqual(decode(.init(minimumFrequency: 200, maximumFrequency: 300)), [note])
        XCTAssertEqual(decode(.init(minimumFrequency: 300, maximumFrequency: 200)), [])
        XCTAssertEqual(BasicPitch.bin(forFrequency: 10), 0)
        XCTAssertEqual(BasicPitch.bin(forFrequency: 20_000), 88)
        XCTAssertNil(BasicPitch.bin(forFrequency: .nan))
    }

    // MARK: - Melodia shortcut vs. the literal reference algorithm

    func testDecoderMatchesLiteralPortOnRandomMatrices() {
        var rng = SplitMix(seed: 42)
        let settingsChoices: [BasicPitch.DecoderSettings] = [
            .init(), .init(inferOnsets: false), .init(melodiaTrick: false),
            .init(onsetThreshold: 0.3, frameThreshold: 0.2, minimumNoteLengthMs: 50, energyTolerance: 4),
            .init(onsetThreshold: 0.7, frameThreshold: 0.5, minimumNoteLengthMs: 0),
            .init(minimumFrequency: 80, maximumFrequency: 1500),
            .init(onsetThreshold: 0, frameThreshold: 0.4, energyTolerance: 2),
        ]
        for trial in 0..<24 {
            let n = 3 + rng.int(below: 70)
            let levels = [0, 4, 8, 16][trial % 4]  // 0 = continuous values, otherwise k / levels (many ties)
            func value(_ scale: Double) -> Float {
                let u = rng.unit() * scale
                return levels == 0 ? Float(u) : Float((u * Double(levels)).rounded(.down)) / Float(levels)
            }
            var frames = (0..<(n * 88)).map { _ in value(0.35) }
            var onsets = (0..<(n * 88)).map { _ in value(0.4) }
            for _ in 0..<rng.int(below: 30) {
                let bin = rng.int(below: 88), start = rng.int(below: n), length = 1 + rng.int(below: 40)
                for t in start..<min(n, start + length) { frames[t * 88 + bin] = max(0.3, value(1)) }
                if rng.unit() < 0.7 { onsets[start * 88 + bin] = max(0.4, value(1)) }
            }
            for settings in settingsChoices {
                let fast = BasicPitch.frameNotes(frames: frames, onsets: onsets, frameCount: n, settings: settings)
                let literal = literalFrameNotes(frames: frames, onsets: onsets, frameCount: n, settings: settings)
                XCTAssertEqual(fast, literal, "trial \(trial), n \(n), settings \(settings)")
            }
        }
    }

    func testFiveMinuteDecodeIsFast() {
        let n = 25_840  // 5 minutes of frames
        var rng = SplitMix(seed: 7)
        var frames = (0..<(n * 88)).map { _ in Float(0.02 + 0.08 * rng.unit()) }
        var onsets = (0..<(n * 88)).map { _ in Float(0.01 + 0.05 * rng.unit()) }
        for _ in 0..<3000 {
            let bin = 15 + rng.int(below: 60), start = rng.int(below: n), length = 8 + rng.int(below: 90)
            let level = 0.4 + 0.5 * rng.unit()
            for t in start..<min(n, start + length) {
                frames[t * 88 + bin] = Float(level * (1 - 0.4 * Double(t - start) / Double(length)))
            }
            onsets[start * 88 + bin] = Float(0.5 + 0.45 * rng.unit())
        }
        for _ in 0..<(n * 88 / 50) {
            frames[rng.int(below: n * 88)] = Float(0.3 + 0.4 * rng.unit())
        }
        let started = Date()
        let notes = BasicPitch.notes(frames: frames, onsets: onsets, frameCount: n)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(notes.count, 2000)
        XCTAssertLessThan(elapsed, 3, "decoding 5 minutes took \(elapsed) s")
        print("BasicPitch: decoded \(n) frames into \(notes.count) notes in \(String(format: "%.3f", elapsed)) s")
    }

    // MARK: - Resampling

    func testResampleKeepsSineFrequencyAndAmplitude() {
        for (rate, frequency) in [(44_100.0, 440.0), (48_000, 440), (16_000, 1000), (96_000, 3000), (44_100.5, 440),
                                  (44_100, 8000)] {
            let input = sine(frequency, amplitude: 0.5, rate: rate, seconds: 1)
            let output = BasicPitch.resample(input, from: rate)
            XCTAssertEqual(output.count, Int((Double(input.count) * (22050 / rate)).rounded(.up)))
            let middle = Array(output[2205..<(output.count - 2205)])
            XCTAssertEqual(rms(middle) * 2.squareRoot(), 0.5, accuracy: 0.5 * 0.02, "\(rate) Hz, \(frequency) Hz")
            XCTAssertEqual(estimatedFrequency(middle, rate: 22050), frequency, accuracy: frequency * 1e-3,
                           "\(rate) Hz, \(frequency) Hz")
        }
    }

    func testResampleSuppressesAliasing() {
        for (rate, frequency) in [(48_000.0, 15_000.0), (44_100, 15_000), (44_100, 12_000), (96_000, 30_000)] {
            let output = BasicPitch.resample(sine(frequency, amplitude: 0.5, rate: rate, seconds: 1), from: rate)
            let middle = Array(output[2205..<(output.count - 2205)])
            XCTAssertLessThan(rms(middle), 0.5 / 2.squareRoot() * 1e-3, "\(frequency) Hz at \(rate) Hz")
        }
    }

    func testResampleEdgeCases() {
        let input: [Float] = [0.1, -0.2, 0.3]
        XCTAssertEqual(BasicPitch.resample(input, from: 22050), input)
        XCTAssertEqual(BasicPitch.resample([], from: 44100), [])
        XCTAssertEqual(BasicPitch.resample(input, from: 0), [])
        XCTAssertEqual(BasicPitch.resample(input, from: .nan), [])
        XCTAssertEqual(BasicPitch.resample(input, from: 44100).count, 2)
        let dc = BasicPitch.resample([Float](repeating: 0.25, count: 4800), from: 48000)
        for value in dc[200..<(dc.count - 200)] { XCTAssertEqual(value, 0.25, accuracy: 1e-5) }
    }

    // MARK: - Helpers

    private func assertMatches(_ found: [BasicPitch.FrameNote], _ expected: [[Double]], _ label: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(found.count, expected.count, label, file: file, line: line)
        for (note, row) in zip(found, expected) {
            XCTAssertEqual([note.startFrame, note.endFrame, note.midi], [Int(row[0]), Int(row[1]), Int(row[2])],
                           label, file: file, line: line)
            XCTAssertEqual(note.amplitude, row[3], accuracy: 1e-5, label, file: file, line: line)
        }
    }

    /// sum((i + 1) * bits(values[i])) mod 2^64, as computed by the fixture generator.
    private func checksum(_ values: [Float]) -> UInt64 {
        var hash: UInt64 = 0
        for (i, v) in values.enumerated() { hash = hash &+ UInt64(i + 1) &* UInt64(v.bitPattern) }
        return hash
    }

    private func sine(_ frequency: Double, amplitude: Double, rate: Double, seconds: Double) -> [Float] {
        (0..<Int(rate * seconds)).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    private func rms(_ x: [Float]) -> Double {
        (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
    }

    /// Frequency from the first and last upward zero crossings (linearly interpolated).
    private func estimatedFrequency(_ x: [Float], rate: Double) -> Double {
        var crossings: [Double] = []
        for i in 1..<x.count where x[i - 1] < 0 && x[i] >= 0 {
            crossings.append(Double(i - 1) + Double(-x[i - 1] / (x[i] - x[i - 1])))
        }
        guard let first = crossings.first, let last = crossings.last, crossings.count > 1 else { return 0 }
        return Double(crossings.count - 1) * rate / (last - first)
    }

    // MARK: Fixtures

    private struct ClipFixture: Decodable {
        let name: String
        let sampleCount: Int
        let windowCount: Int
        let frameCount: Int
        let windowChecksums: [String]
        let stitchedChecksums: [String: String]
        let variants: [String: Variant]
        let mulawTable: [Double]?
    }

    private struct Variant: Decodable {
        let settings: Settings
        /// [startFrame, endFrame, midi, amplitude] (+ [startSeconds, endSeconds] for the clips).
        let notes: [[Double]]
    }

    private struct Settings: Decodable {
        let onsetThreshold: Double
        let frameThreshold: Double
        let minimumNoteLengthMs: Double
        let minimumNoteFrames: Int
        let inferOnsets: Bool
        let melodiaTrick: Bool
        let energyTolerance: Int
        let minimumFrequency: Double?
        let maximumFrequency: Double?

        var decoderSettings: BasicPitch.DecoderSettings {
            .init(onsetThreshold: onsetThreshold, frameThreshold: frameThreshold,
                  minimumNoteLengthMs: minimumNoteLengthMs, inferOnsets: inferOnsets, melodiaTrick: melodiaTrick,
                  energyTolerance: energyTolerance, minimumFrequency: minimumFrequency,
                  maximumFrequency: maximumFrequency)
        }
    }

    private struct ReferenceFixture: Decodable {
        struct StitchCase: Decodable {
            let sampleCount: Int
            /// Per window: [first nonzero index, last nonzero index, nonzero count] for all-ones audio.
            let windows: [[Int]]
            let frameCount: Int
            /// Stitched rows as runs of [window, first frame in window, count].
            let rowRuns: [[Int]]
        }

        struct FrameTimes: Decodable {
            let times: [Double]
        }

        let stitchCases: [StitchCase]
        let frameTimes: FrameTimes
        let minimumNoteFrames: [String: Int]
        let clips: [String]
    }

    private struct RandomFixture: Decodable {
        struct Case: Decodable {
            let name: String
            let frameCount: Int
            let offset: Int
            let variants: [String: Variant]
        }

        let divisor: Int
        let cases: [Case]
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BasicPitch").appendingPathComponent(name)
    }

    private func decodeJSON<T: Decodable>(_ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: fixtureURL(name)))
    }

    private func referenceFixture() throws -> ReferenceFixture { try decodeJSON("reference.json") }

    private func clipFixture(_ name: String) throws -> ClipFixture { try decodeJSON(name + ".json") }

    /// Mu-law coded audio decoded through the table stored with the clip.
    private func clipAudio(_ clip: ClipFixture) throws -> [Float] {
        let table = try XCTUnwrap(clip.mulawTable).map { Float($0) }
        let codes = try Inflate.inflate(Data(contentsOf: fixtureURL(clip.name + ".audio.bin")))
        return codes.map { table[Int($0)] }
    }

    /// Per-window note and onset outputs, stored as byte-planar little-endian UInt16 k meaning k / 65536.
    private func clipOutputs(_ clip: ClipFixture) throws -> (note: [[Float]], onset: [[Float]]) {
        let bytes = try [UInt8](Inflate.inflate(Data(contentsOf: fixtureURL(clip.name + ".outputs.bin"))))
        let windowSize = BasicPitch.framesPerWindow * 88
        let count = clip.windowCount * windowSize
        XCTAssertEqual(bytes.count, 4 * count)
        func matrix(at offset: Int) -> [[Float]] {
            let values = (0..<count).map { i in
                Float(UInt16(bytes[offset + i]) << 8 | UInt16(bytes[offset + count + i])) / 65536
            }
            return (0..<clip.windowCount).map { Array(values[($0 * windowSize)..<(($0 + 1) * windowSize)]) }
        }
        return (matrix(at: 0), matrix(at: 2 * count))
    }
}

/// Deterministic random numbers for the tests.
private struct SplitMix {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func int(below bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

/// Line-by-line port of basic-pitch's `output_to_notes_polyphonic` (with `get_infered_onsets`,
/// `constrain_frequency` and a full argmax per melodia iteration), used to check the optimised decoder.
private func literalFrameNotes(frames input: [Float], onsets onsetInput: [Float], frameCount n: Int,
                               settings: BasicPitch.DecoderSettings) -> [BasicPitch.FrameNote] {
    let bins = 88
    var frames = input
    var rawOnsets = onsetInput
    let allowed = settings.allowedBins
    for t in 0..<n {
        for f in 0..<bins where !allowed.contains(f) {
            frames[t * bins + f] = 0
            rawOnsets[t * bins + f] = 0
        }
    }
    var onsets = rawOnsets.map(Double.init)
    if settings.inferOnsets {
        var diff = [Double](repeating: 0, count: n * bins)
        for t in 2..<max(2, n) {
            for f in 0..<bins {
                let x = Double(frames[t * bins + f])
                let d = min(x - Double(frames[(t - 1) * bins + f]), x - Double(frames[(t - 2) * bins + f]))
                diff[t * bins + f] = d < 0 ? 0 : d
            }
        }
        let maxOnset = Double(rawOnsets.max()!)
        let maxDiff = diff.max()!
        for i in onsets.indices {
            let scaled = maxOnset * diff[i] / maxDiff
            onsets[i] = scaled.isNaN ? .nan : max(onsets[i], scaled)
        }
    }
    var peaks = [Double](repeating: 0, count: n * bins)
    for t in 0..<n {
        for f in 0..<bins {
            let v = onsets[t * bins + f]
            if v > onsets[max(t - 1, 0) * bins + f] && v > onsets[min(t + 1, n - 1) * bins + f] {
                peaks[t * bins + f] = v
            }
        }
    }

    let threshold = settings.frameThreshold
    let minimum = settings.minimumNoteFrames
    let tolerance = settings.energyTolerance
    var remaining = frames.map(Double.init)
    var notes: [BasicPitch.FrameNote] = []
    func clear(_ t: Int, _ f: Int) {
        remaining[t * bins + f] = 0
        if f < bins - 1 { remaining[t * bins + f + 1] = 0 }
        if f > 0 { remaining[t * bins + f - 1] = 0 }
    }
    func mean(_ f: Int, _ start: Int, _ end: Int) -> Double {
        var sum = 0.0
        for t in start..<end { sum += Double(frames[t * bins + f]) }
        return sum / Double(end - start)
    }
    for index in (0..<(n * bins)).reversed() where peaks[index] >= settings.onsetThreshold {
        let start = index / bins, f = index % bins
        if start >= n - 1 { continue }
        var i = start + 1
        var k = 0
        while i < n - 1 && k < tolerance {
            if remaining[i * bins + f] < threshold { k += 1 } else { k = 0 }
            i += 1
        }
        i -= k
        if i - start <= minimum { continue }
        for t in start..<i { clear(t, f) }
        notes.append(.init(startFrame: start, endFrame: i, midi: f + 21, amplitude: mean(f, start, i)))
    }
    if settings.melodiaTrick {
        while true {
            var best = -Double.infinity
            var bestIndex = 0
            var sawNaN = false
            remaining.withUnsafeBufferPointer { r in
                for i in 0..<r.count {
                    if r[i].isNaN { sawNaN = true; break }
                    if r[i] > best { best = r[i]; bestIndex = i }
                }
            }
            if sawNaN || !(best > threshold) { break }
            let middle = bestIndex / bins, f = bestIndex % bins
            remaining[bestIndex] = 0
            var i = middle + 1
            var k = 0
            while i < n - 1 && k < tolerance {
                if remaining[i * bins + f] < threshold { k += 1 } else { k = 0 }
                clear(i, f)
                i += 1
            }
            let end = i - 1 - k
            i = middle - 1
            k = 0
            while i > 0 && k < tolerance {
                if remaining[i * bins + f] < threshold { k += 1 } else { k = 0 }
                clear(i, f)
                i -= 1
            }
            let start = i + 1 + k
            if end - start <= minimum { continue }
            notes.append(.init(startFrame: start, endFrame: end, midi: f + 21, amplitude: mean(f, start, end)))
        }
    }
    return notes.sorted { ($0.startFrame, $0.midi, $0.endFrame) < ($1.startFrame, $1.midi, $1.endFrame) }
}
