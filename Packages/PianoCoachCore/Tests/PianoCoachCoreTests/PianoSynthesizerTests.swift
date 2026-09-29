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
}
