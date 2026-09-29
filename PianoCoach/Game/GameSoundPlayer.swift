import AVFoundation
import Foundation
import PianoCoachCore

/// Plays notes with the built-in piano sound (`PianoSynthesizer`) through its own AVAudioEngine.
///
/// Not main-actor isolated on purpose: the source node's render block runs on the audio thread and
/// must not be a main-actor closure.
final class GameSoundPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var synth: PianoSynthesizer?
    private let lock = NSLock()

    var isRunning: Bool { lock.withLock { engine.isRunning } }

    /// Starts the audio engine (idempotent).
    func start() throws {
        try lock.withLock {
            if engine.isRunning { return }
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            // Keep the microphone's play-and-record session if it is running; otherwise just play.
            if session.category != .playAndRecord {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
            #endif
            if sourceNode == nil {
                let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
                let sampleRate = rate > 0 ? rate : 48_000
                guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
                let synth = PianoSynthesizer(sampleRate: sampleRate)
                let node = Self.makeSourceNode(format: format, synth: synth)
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: format)
                self.synth = synth
                sourceNode = node
            }
            engine.prepare()
            try engine.start()
        }
    }

    func stop() {
        lock.withLock {
            synth?.allNotesOff()
            engine.stop()
        }
    }

    func noteOn(_ midi: Int, velocity: Float = 0.7) {
        lock.withLock { synth }?.noteOn(midi, velocity: velocity)
    }

    func noteOff(_ midi: Int) {
        lock.withLock { synth }?.noteOff(midi)
    }

    func allNotesOff() {
        lock.withLock { synth }?.allNotesOff()
    }

    /// Built in a static (non-isolated) context so the render block carries no actor isolation.
    private static func makeSourceNode(format: AVAudioFormat, synth: PianoSynthesizer) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let first = buffers.first, let data = first.mData else { return noErr }
            let samples = data.assumingMemoryBound(to: Float.self)
            synth.render(into: samples, frameCount: Int(frameCount))
            // A mono format has one buffer; copy just in case the engine asks for more.
            for buffer in buffers.dropFirst() {
                buffer.mData?.copyMemory(from: data, byteCount: Int(frameCount) * MemoryLayout<Float>.size)
            }
            return noErr
        }
    }
}
