import XCTest
@testable import PianoCoachCore

final class PianoSynthesizerTests: XCTestCase {
    private func render(_ synth: PianoSynthesizer, seconds: Double) -> [Float] {
        var out: [Float] = []
        var buffer = [Float](repeating: 0, count: 512)
        let blocks = Int(seconds * synth.sampleRate / 512)
        for _ in 0..<blocks {
            buffer.withUnsafeMutableBufferPointer { synth.render(into: $0.baseAddress!, frameCount: 512) }
            out += buffer
        }
        return out
    }

    func testPlaysTheRequestedPitch() {
        let synth = PianoSynthesizer(sampleRate: 48_000)
        synth.noteOn(69)
        let audio = render(synth, seconds: 0.3)
        let fft = RealFFT(size: 8192)
        let mags = fft.magnitudes(Array(audio[2000..<(2000 + 8192)]))
        let peak = mags.indices.max { mags[$0] < mags[$1] }!
        XCTAssertEqual(Double(peak) * 48_000 / 8192, 440, accuracy: 6)
        XCTAssertLessThan(audio.map(abs).max()!, 1)
    }

    func testNoteOffFadesOutAndFreesTheVoice() {
        let synth = PianoSynthesizer(sampleRate: 48_000)
        synth.noteOn(60)
        _ = render(synth, seconds: 0.1)
        XCTAssertEqual(synth.activeVoiceCount, 1)
        synth.noteOff(60)
        let tail = render(synth, seconds: 1.0)
        XCTAssertEqual(synth.activeVoiceCount, 0)
        XCTAssertLessThan(tail.suffix(1000).map(abs).max()!, 1e-3)
    }

    func testSilenceWhenIdleAndVoiceLimit() {
        let synth = PianoSynthesizer(sampleRate: 44_100, maxVoices: 4)
        XCTAssertEqual(render(synth, seconds: 0.05).map(abs).max(), 0)
        for m in 60..<70 { synth.noteOn(m) }
        _ = render(synth, seconds: 0.02)
        XCTAssertEqual(synth.activeVoiceCount, 4)
        synth.allNotesOff()
        _ = render(synth, seconds: 1.5)
        XCTAssertEqual(synth.activeVoiceCount, 0)
    }

    // MARK: - Recorded samples

    /// A fake recording of `midi`: a decaying sine at the key's frequency.
    private func recording(_ midi: Int, sampleRate: Double = 44_100, seconds: Double = 1) -> PianoSample {
        let f = Pitch.frequency(midi: midi)
        let samples = (0..<Int(seconds * sampleRate)).map { i -> Float in
            let t = Double(i) / sampleRate
            return Float(0.1 * sin(2 * .pi * f * t) * exp(-t * 2))
        }
        return PianoSample(midi: midi, sampleRate: sampleRate, samples: samples)
    }

    private func peakFrequency(_ audio: [Float], sampleRate: Double) -> Double {
        let fft = RealFFT(size: 8192)
        let mags = fft.magnitudes(Array(audio[1000..<(1000 + 8192)]))
        let peak = mags.indices.max { mags[$0] < mags[$1] }!
        return Double(peak) * sampleRate / 8192
    }

    func testPlaysRecordingsAndRepitchesNearbyKeys() {
        let synth = PianoSynthesizer(sampleRate: 48_000)
        synth.loadSamples([recording(69), recording(81)])
        XCTAssertTrue(synth.hasSamples)
        synth.noteOn(69)
        XCTAssertEqual(peakFrequency(render(synth, seconds: 0.3), sampleRate: 48_000), 440, accuracy: 6)
        synth.allNotesOff()
        _ = render(synth, seconds: 1)
        // B4 has no recording: A4's is played a whole tone higher.
        synth.noteOn(71)
        XCTAssertEqual(peakFrequency(render(synth, seconds: 0.3), sampleRate: 48_000), 493.9, accuracy: 7)
    }

    func testRecordingEndsOrIsDamped() {
        let synth = PianoSynthesizer(sampleRate: 48_000)
        synth.loadSamples([recording(60, seconds: 0.5)])
        synth.noteOn(60)
        _ = render(synth, seconds: 0.2)
        XCTAssertEqual(synth.activeVoiceCount, 1)
        _ = render(synth, seconds: 0.5)
        XCTAssertEqual(synth.activeVoiceCount, 0, "the voice ends with its recording")
        synth.noteOn(60)
        _ = render(synth, seconds: 0.1)
        synth.noteOff(60)
        let tail = render(synth, seconds: 0.2)
        XCTAssertLessThan(tail.suffix(500).map(abs).max()!, 0.01, "the damper silences a released key")
    }

    func testVelocityAndLimiter() {
        let soft = PianoSynthesizer(sampleRate: 48_000)
        let loud = PianoSynthesizer(sampleRate: 48_000)
        for synth in [soft, loud] { synth.loadSamples([recording(60)]) }
        soft.noteOn(60, velocity: 0.3)
        loud.noteOn(60, velocity: 1)
        let softPeak = render(soft, seconds: 0.2).map(abs).max()!
        let loudPeak = render(loud, seconds: 0.2).map(abs).max()!
        XCTAssertGreaterThan(loudPeak, softPeak * 2.5)

        // Twenty loud keys at once stay below full scale.
        let many = PianoSynthesizer(sampleRate: 48_000)
        many.loadSamples((40..<80).map { recording($0) })
        for m in 50..<70 { many.noteOn(m, velocity: 1) }
        XCTAssertLessThan(render(many, seconds: 0.3).map(abs).max()!, 1)
    }

    func testKeysFarFromAnyRecordingUseTheAdditiveSound() {
        let synth = PianoSynthesizer(sampleRate: 48_000)
        synth.loadSamples([recording(60)])
        synth.noteOn(90)
        XCTAssertEqual(peakFrequency(render(synth, seconds: 0.3), sampleRate: 48_000), Pitch.frequency(midi: 90), accuracy: 8)
    }
}
