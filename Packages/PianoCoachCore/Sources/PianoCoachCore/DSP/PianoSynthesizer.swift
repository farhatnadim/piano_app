import Foundation

/// A small real-time piano-like synthesizer (additive partials with a pitch-dependent decay), used to
/// let the child hear a song at the game's current speed.
///
/// `noteOn`/`noteOff` may be called from any thread; `render` runs on the audio thread and only holds
/// the lock long enough to pick up queued notes.
public final class PianoSynthesizer: @unchecked Sendable {
    public let sampleRate: Double
    public let maxVoices: Int

    private struct Voice {
        var midi: Int
        var phases: [Double]
        var increments: [Double]
        var gains: [Float]
        var decayPerSample: Float
        var level: Float
        var releasing = false
        var releasePerSample: Float
        var attack: Float = 0
    }

    private enum Command { case on(Int, Float), off(Int), allOff }

    private let lock = NSLock()
    private var queued: [Command] = []           // guarded by `lock`
    private var voices: [Voice] = []             // audio thread only
    private var volumeValue: Float = 0.6         // guarded by `lock`

    private static let tableSize = 4096
    private static let sineTable: [Float] = (0...tableSize).map { Float(sin(2 * Double.pi * Double($0) / Double(tableSize))) }

    public init(sampleRate: Double, maxVoices: Int = 24) {
        self.sampleRate = sampleRate
        self.maxVoices = maxVoices
    }

    /// Overall loudness 0...1.
    public var volume: Float {
        get { lock.withLock { volumeValue } }
        set { lock.withLock { volumeValue = max(0, min(1, newValue)) } }
    }

    public func noteOn(_ midi: Int, velocity: Float = 0.7) {
        lock.withLock { queued.append(.on(midi, max(0.05, min(1, velocity)))) }
    }

    public func noteOff(_ midi: Int) {
        lock.withLock { queued.append(.off(midi)) }
    }

    public func allNotesOff() {
        lock.withLock { queued.append(.allOff) }
    }

    /// Number of voices currently sounding (audio-thread view; for tests).
    public var activeVoiceCount: Int { voices.count }

    /// Renders `frameCount` mono samples (overwriting the buffer).
    public func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let (commands, volume) = lock.withLock { () -> ([Command], Float) in
            defer { queued.removeAll(keepingCapacity: true) }
            return (queued, volumeValue)
        }
        for command in commands { apply(command) }
        for i in 0..<frameCount { buffer[i] = 0 }
        guard !voices.isEmpty else { return }

        let table = Self.sineTable
        let size = Double(Self.tableSize)
        let attackStep = Float(1 / (0.004 * sampleRate))
        table.withUnsafeBufferPointer { sine in
            for v in voices.indices {
                var voice = voices[v]
                for i in 0..<frameCount {
                    var sample: Float = 0
                    for p in 0..<voice.phases.count {
                        let position = voice.phases[p] * size
                        let index = Int(position)
                        let frac = Float(position - Double(index))
                        sample += voice.gains[p] * (sine[index] + (sine[index + 1] - sine[index]) * frac)
                        var next = voice.phases[p] + voice.increments[p]
                        if next >= 1 { next -= 1 }
                        voice.phases[p] = next
                    }
                    if voice.attack < 1 { voice.attack = min(1, voice.attack + attackStep) }
                    buffer[i] += sample * voice.level * voice.attack * volume * 0.25
                    voice.level *= voice.releasing ? voice.releasePerSample : voice.decayPerSample
                }
                voices[v] = voice
            }
        }
        voices.removeAll { $0.level < 0.0005 }
    }

    private func apply(_ command: Command) {
        switch command {
        case .on(let midi, let velocity):
            if let i = voices.firstIndex(where: { $0.midi == midi && !$0.releasing }) {
                voices[i].releasing = true           // re-striking a key damps the old string
            }
            if voices.count >= maxVoices, let quietest = voices.indices.min(by: { voices[$0].level < voices[$1].level }) {
                voices.remove(at: quietest)
            }
            voices.append(makeVoice(midi: midi, velocity: velocity))
        case .off(let midi):
            for i in voices.indices where voices[i].midi == midi { voices[i].releasing = true }
        case .allOff:
            for i in voices.indices { voices[i].releasing = true }
        }
    }

    private func makeVoice(midi: Int, velocity: Float) -> Voice {
        let f0 = Pitch.frequency(midi: midi)
        var increments: [Double] = []
        var gains: [Float] = []
        for h in 1...6 {
            let hd = Double(h)
            let f = hd * f0 * (1 + 0.0004 * hd * hd).squareRoot()
            if f > sampleRate * 0.45 { break }
            increments.append(f / sampleRate)
            gains.append(Float(1 / pow(hd, 1.3)))
        }
        let decaySeconds = 2.2 * pow(261.6 / f0, 0.45)
        return Voice(midi: midi,
                     phases: Array(repeating: 0, count: increments.count),
                     increments: increments,
                     gains: gains,
                     decayPerSample: Float(exp(-1 / (decaySeconds * sampleRate))),
                     level: velocity,
                     releasePerSample: Float(exp(-1 / (0.08 * sampleRate))))
    }
}
