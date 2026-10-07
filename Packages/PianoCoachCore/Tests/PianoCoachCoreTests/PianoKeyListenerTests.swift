import Foundation
import XCTest
@testable import PianoCoachCore

/// The microphone listener against real piano recordings (FluidR3 samples, CC BY 3.0) and synthetic talk
/// (eSpeak NG), mixed the way a child's practice sounds: notes, wrong notes, chords, an old out-of-tune
/// piano, and the family talking, clapping or running a fan in the background.
final class PianoKeyListenerTests: XCTestCase {
    private static let rate = 48_000.0
    private static let scale = [60, 62, 64, 65, 67, 69, 71, 72]

    // MARK: Single keys

    func testHearsEachKeyAlone() throws {
        for midi in [43, 48, 60, 61, 62, 64, 65, 67, 69, 71, 72, 84, 93] {
            let audio = try mix([(midi, 0.3, 0)], length: 1.4)
            let heard = listen(audio) { _ in [midi] }
            XCTAssertEqual(heard.map(\.keys), [[midi]], "key \(midi)")
            XCTAssertEqual(heard.first?.isWrong, false, "key \(midi)")
            // Low notes are timed by a higher partial; all within a few hundredths of a second.
            XCTAssertEqual(heard.first?.time ?? 0, 0.3, accuracy: midi < 48 ? 0.12 : 0.03, "key \(midi)")
        }
    }

    func testReportsTheWrongKey() throws {
        let neighbour = listen(try mix([(61, 0.3, 0)], length: 1.4)) { _ in [60] }
        XCTAssertEqual(neighbour.count, 1)
        XCTAssertEqual(neighbour.first?.keys, [61])
        XCTAssertEqual(neighbour.first?.isWrong, true)

        let unexpected = listen(try mix([(67, 0.3, 0)], length: 1.4)) { _ in [] }
        XCTAssertEqual(unexpected.map(\.keys), [[67]])
        XCTAssertEqual(unexpected.first?.isWrong, true)
    }

    func testHearsAChord() throws {
        let audio = try mix([(60, 0.3, 0), (64, 0.3, -2), (67, 0.3, -2)], length: 1.4)
        let heard = listen(audio) { _ in [60, 64, 67] }
        XCTAssertEqual(heard.map(\.keys), [[60, 64, 67]])
    }

    // MARK: Melodies

    func testHearsAMelody() throws {
        let plan = Self.scale.enumerated().map { (midi: $0.element, start: 0.4 + 0.45 * Double($0.offset)) }
        let heard = listen(try mix(plan.map { ($0.midi, $0.start, 0) }, length: 4.6), expecting: plan)
        XCTAssertEqual(heard.map(\.keys), Self.scale.map { [$0] })
        XCTAssertFalse(heard.contains(where: \.isWrong))
        for (h, note) in zip(heard, plan) {
            XCTAssertEqual(h.time, note.start, accuracy: 0.03)
        }
    }

    func testCatchesAWrongNoteInAMelody() throws {
        let plan = Self.scale.enumerated().map { (midi: $0.element, start: 0.4 + 0.45 * Double($0.offset)) }
        // The child plays F instead of E.
        let played = plan.enumerated().map { ($0.offset == 2 ? 65 : $0.element.midi, $0.element.start, 0.0) }
        let heard = listen(try mix(played, length: 4.6), expecting: plan)
        XCTAssertEqual(heard.count, 8)
        XCTAssertEqual(heard.filter(\.isWrong).map(\.keys), [[65]])
        XCTAssertEqual(heard.filter(\.isWrong).first?.time ?? 0, plan[2].start, accuracy: 0.03)
        XCTAssertEqual(heard.filter { !$0.isWrong }.map(\.keys), [60, 62, 65, 67, 69, 71, 72].map { [$0] })
    }

    func testHearsRepeatedNotes() throws {
        let plan = (0..<6).map { (midi: 64, start: 0.4 + 0.4 * Double($0)) }
        var audio = noise(count: Int(3.2 * Self.rate), level: 3e-4)
        // Each note is let go (damped) before the next.
        var note = try Self.note(64, rate: Self.rate)
        note = Array(note.prefix(Int(0.33 * Self.rate)))
        let fade = Int(0.05 * Self.rate)
        for i in 0..<fade { note[note.count - fade + i] *= Float(fade - i) / Float(fade) }
        for p in plan { add(note, to: &audio, at: p.start) }
        let heard = listen(audio, expecting: plan)
        XCTAssertEqual(heard.map(\.keys), Array(repeating: [64], count: 6))
    }

    func testFollowsAPianoThatIsOutOfTune() throws {
        let plan = Self.scale.enumerated().map { (midi: $0.element, start: 0.4 + 0.45 * Double($0.offset)) }
        let audio = try mix(plan.map { ($0.midi, $0.start, 0) }, length: 4.6, cents: -25)
        let listener = PianoKeyListener(sampleRate: Self.rate)
        let heard = listen(audio, with: listener, expecting: plan)
        XCTAssertEqual(heard.map(\.keys), Self.scale.map { [$0] })
        XCTAssertFalse(heard.contains(where: \.isWrong))
        XCTAssertEqual(listener.tuningCents, -25, accuracy: 8)
    }

    func testWorksAtOtherSampleRates() throws {
        for rate in [44_100.0, 22_050.0] {
            let plan = Self.scale.enumerated().map { (midi: $0.element, start: 0.4 + 0.45 * Double($0.offset)) }
            let audio = try mix(plan.map { ($0.midi, $0.start, 0) }, length: 4.6, rate: rate)
            let heard = listen(audio, with: PianoKeyListener(sampleRate: rate), expecting: plan)
            XCTAssertEqual(heard.map(\.keys), Self.scale.map { [$0] }, "at \(rate) Hz")
        }
    }

    // MARK: Background sound

    func testIgnoresTalking() throws {
        let talk = try Self.talk(rate: Self.rate)
        for levelDB in [-30.0, -20.0, -10.0] {
            let gain = Float(pow(10, levelDB / 20) / 0.1)
            let audio = talk.map { $0 * gain }
            // Waiting for the notes of a scale while someone talks: nothing is heard, right or wrong.
            let whileWaiting = listen(audio) { t in [Self.scale[Int(t / 0.7) % Self.scale.count]] }
            XCTAssertEqual(whileWaiting, [], "talk at \(levelDB) dBFS")
            let whileIdle = listen(audio) { _ in [] }
            XCTAssertEqual(whileIdle, [], "talk at \(levelDB) dBFS")
        }
    }

    func testIgnoresClapsAndHiss() {
        let count = Int(6 * Self.rate)
        var audio = noise(count: count, level: 0.02, seed: 7)
        var rng = XorShift(seed: 11)
        var t = 0.3
        while t < 5.8 {
            let start = Int(t * Self.rate)
            for i in 0..<Int(0.05 * Self.rate) {
                audio[start + i] += 0.5 * rng.next() * Float(exp(-Double(i) / (0.01 * Self.rate)))
            }
            t += 0.37
        }
        XCTAssertEqual(listen(audio) { _ in [60, 64] }, [])
    }

    func testPlayingWhileSomeoneTalks() throws {
        let plan = Self.scale.enumerated().map { (midi: $0.element, start: 0.4 + 0.45 * Double($0.offset)) }
        let played = plan.enumerated().map { ($0.offset == 2 ? 65 : $0.element.midi, $0.element.start, 0.0) }
        var audio = try mix(played, length: 4.6)
        let talk = try Self.talk(rate: Self.rate)
        let pianoRMS = (audio.reduce(0) { $0 + $1 * $1 } / Float(audio.count)).squareRoot()
        let gain = pianoRMS / 0.1 * Float(pow(10, -12.0 / 20))
        for i in audio.indices where i < talk.count { audio[i] += talk[i] * gain }
        let heard = listen(audio, expecting: plan)
        // Talking may hide a note or a wrong note, but never makes one up.
        let right = heard.filter { !$0.isWrong }.flatMap(\.keys)
        XCTAssertGreaterThanOrEqual(Set(right).intersection([60, 62, 67, 69, 71, 72]).count, 5, "\(heard)")
        XCTAssertTrue(heard.filter(\.isWrong).allSatisfy { $0.keys == [65] }, "\(heard)")
        XCTAssertFalse(right.contains(64), "\(heard)")
    }

    func testResetStartsOver() throws {
        let listener = PianoKeyListener(sampleRate: Self.rate)
        _ = listen(try mix([(60, 0.3, 0)], length: 1.4), with: listener) { _ in [60] }
        listener.reset()
        XCTAssertEqual(listener.clock, 0)
        let heard = listen(try mix([(64, 0.3, 0)], length: 1.4), with: listener) { _ in [64] }
        XCTAssertEqual(heard.map(\.keys), [[64]])
    }

    // MARK: - Helpers

    private typealias Plan = [(midi: Int, start: Double)]

    /// What the game would expect: each written note from just before it is due until a little after.
    private func listen(_ audio: [Float], with listener: PianoKeyListener? = nil, expecting plan: Plan)
        -> [PianoKeyListener.Heard] {
        listen(audio, with: listener) { t in
            Set(plan.filter { t >= $0.start - 0.1 && t <= $0.start + 0.3 }.map(\.midi))
        }
    }

    private func listen(_ audio: [Float], with listener: PianoKeyListener? = nil,
                        expected: (Double) -> Set<Int>) -> [PianoKeyListener.Heard] {
        let listener = listener ?? PianoKeyListener(sampleRate: Self.rate)
        let rate = listener.configuration.sampleRate
        let start = listener.clock
        var heard: [PianoKeyListener.Heard] = []
        var i = 0
        while i < audio.count {
            listener.expectedKeys = expected(Double(i) / rate)
            let end = min(audio.count, i + 1024)
            heard += listener.process(Array(audio[i..<end])).map {
                var h = $0
                h.time -= start
                return h
            }
            i = end
        }
        return heard
    }

    /// Notes (MIDI, start s, gain dB) mixed over a faint hiss.
    private func mix(_ notes: [(Int, Double, Double)], length: Double, rate: Double = rate, cents: Double = 0)
        throws -> [Float] {
        var out = noise(count: Int(length * rate), level: 3e-4)
        for (midi, start, gainDB) in notes {
            let gain = Float(pow(10, gainDB / 20))
            add(try Self.note(midi, rate: rate, cents: cents).map { $0 * gain }, to: &out, at: start, rate: rate)
        }
        return out
    }

    private func add(_ sound: [Float], to out: inout [Float], at time: Double, rate: Double = rate) {
        let start = Int(time * rate)
        for i in sound.indices where start + i < out.count { out[start + i] += sound[i] }
    }

    private func noise(count: Int, level: Float, seed: UInt64 = 1) -> [Float] {
        var rng = XorShift(seed: seed)
        return (0..<count).map { _ in rng.next() * level }
    }

    private struct XorShift {
        var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
        mutating func next() -> Float {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Float(Double(state % 2_000_001) / 1_000_000 - 1)
        }
    }

    // MARK: Fixtures

    private static var cache: [String: [Float]] = [:]

    /// A recorded piano note (0.75 s from its attack), resampled to `rate` and optionally detuned.
    private static func note(_ midi: Int, rate: Double, cents: Double = 0) throws -> [Float] {
        resample(try fixture("piano-\(midi)"), from: 22_050, to: rate, cents: cents)
    }

    /// Six seconds of several voices talking, at -20 dBFS RMS (0.1).
    private static func talk(rate: Double) throws -> [Float] {
        resample(try fixture("talk"), from: 16_000, to: rate)
    }

    private static func fixture(_ name: String) throws -> [Float] {
        if let cached = cache[name] { return cached }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PianoKeys/\(name).pcm.deflate")
        let bytes = [UInt8](try Inflate.inflate(Data(contentsOf: url)))
        let samples = stride(from: 0, to: bytes.count - 1, by: 2).map {
            Float(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) / 32768
        }
        cache[name] = samples
        return samples
    }

    /// Linear-interpolation resampling (plenty for the listener, which looks below 5 kHz).
    private static func resample(_ x: [Float], from source: Double, to target: Double, cents: Double = 0) -> [Float] {
        let ratio = source / target * pow(2, cents / 1200)
        let count = Int(Double(x.count - 1) / ratio)
        return (0..<count).map { n in
            let pos = Double(n) * ratio
            let i = Int(pos)
            let f = Float(pos - Double(i))
            return x[i] * (1 - f) + x[min(i + 1, x.count - 1)] * f
        }
    }
}
