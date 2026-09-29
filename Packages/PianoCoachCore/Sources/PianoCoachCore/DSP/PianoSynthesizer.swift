import Foundation

/// A recording of one piano key: mono samples at `sampleRate`.
public struct PianoSample: Sendable {
    public var midi: Int
    public var sampleRate: Double
    public var samples: [Float]

    public init(midi: Int, sampleRate: Double, samples: [Float]) {
        self.midi = midi
        self.sampleRate = sampleRate
        self.samples = samples
    }
}

/// The real-time piano the app plays songs with, at any speed.
///
/// With recorded piano samples loaded (`loadSamples`) every key plays its recording (keys without one use
/// the nearest recording, re-pitched), with the loudness following the velocity and a damper when the key
/// is released. Without samples it falls back to a small additive synthesizer (partials with a
/// pitch-dependent decay).
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
        /// Set for voices that play a recording.
        var recording: Recording?
        var position: Double = 0
    }

    /// A recording ready to play: 16-bit samples (half the memory of floats) and how fast to step
    /// through them for a key.
    private struct Recording {
        var samples: [Int16]
        var scale: Float
        var step: Double
        var gain: Float
    }

    /// Recordings for every key from A0 to C8.
    private struct SampleMap {
        var byKey: [Int: Recording] = [:]
    }

    private enum Command { case on(Int, Float), off(Int), allOff, samples(SampleMap) }

    private let lock = NSLock()
    private var queued: [Command] = []           // guarded by `lock`
    private var voices: [Voice] = []             // audio thread only
    private var sampleMap = SampleMap()          // audio thread only
    private var volumeValue: Float = 0.6         // guarded by `lock`
    private var hasSamplesValue = false          // guarded by `lock`

    private static let tableSize = 4096
    private static let sineTable: [Float] = (0...tableSize).map { Float(sin(2 * Double.pi * Double($0) / Double(tableSize))) }

    public init(sampleRate: Double, maxVoices: Int = 48) {
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

    /// Whether recorded samples are loaded (otherwise the additive sound plays).
    public var hasSamples: Bool { lock.withLock { hasSamplesValue } }

    /// Plays these recordings from now on. Keys without their own recording use the nearest one,
    /// re-pitched; keys more than 6 semitones from any recording keep the additive sound.
    public func loadSamples(_ samples: [PianoSample]) {
        let usable = samples.filter { !$0.samples.isEmpty && $0.sampleRate > 0 }
        guard !usable.isEmpty else { return }
        // One loudness for the whole set: a typical recording's peak plays at about 0.35.
        let peaks = usable.map { $0.samples.reduce(Float(0)) { max($0, abs($1)) } }
        let typicalPeak = max(1e-4, peaks.sorted()[peaks.count / 2])
        let gain = 0.35 / typicalPeak
        var converted: [Int: (samples: [Int16], scale: Float, rate: Double)] = [:]
        for (sample, peak) in zip(usable, peaks) {
            let scale = max(peak, 1e-6) / 32_767
            let ints = sample.samples.map { Int16(max(-32_767, min(32_767, ($0 / scale).rounded()))) }
            converted[sample.midi] = (ints, scale, sample.sampleRate)
        }
        var map = SampleMap()
        let roots = converted.keys.sorted()
        for key in Pitch.lowestPianoMIDI...Pitch.highestPianoMIDI {
            guard let root = roots.min(by: { abs($0 - key) < abs($1 - key) }), abs(root - key) <= 6,
                  let source = converted[root] else { continue }
            let pitch = pow(2, Double(key - root) / 12)
            map.byKey[key] = Recording(samples: source.samples, scale: source.scale,
                                       step: source.rate / sampleRate * pitch, gain: gain)
        }
        lock.withLock {
            queued.append(.samples(map))
            hasSamplesValue = true
        }
    }

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
                if let recording = voice.recording {
                    renderRecording(recording, voice: &voice, into: buffer, frameCount: frameCount, volume: volume)
                    voices[v] = voice
                    continue
                }
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
        // A gentle limiter: many loud notes at once bend smoothly instead of clipping.
        for i in 0..<frameCount {
            let x = buffer[i]
            let magnitude = abs(x)
            if magnitude > 0.8 {
                buffer[i] = (x < 0 ? -1 : 1) * (0.8 + 0.19 * Float(tanh(Double((magnitude - 0.8) / 0.19))))
            }
        }
    }

    private func renderRecording(_ recording: Recording, voice: inout Voice, into buffer: UnsafeMutablePointer<Float>,
                                 frameCount: Int, volume: Float) {
        let last = recording.samples.count - 1
        let gain = recording.gain * recording.scale * volume
        recording.samples.withUnsafeBufferPointer { data in
            for i in 0..<frameCount {
                let index = Int(voice.position)
                guard index < last else {
                    voice.level = 0            // the recording has ended
                    break
                }
                let frac = Float(voice.position - Double(index))
                let a = Float(data[index]), b = Float(data[index + 1])
                buffer[i] += (a + (b - a) * frac) * gain * voice.level
                voice.position += recording.step
                if voice.releasing { voice.level *= voice.releasePerSample }
            }
        }
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
        case .samples(let map):
            sampleMap = map
        }
    }

    private func makeVoice(midi: Int, velocity: Float) -> Voice {
        if let recording = sampleMap.byKey[midi] {
            // Loudness grows faster than linearly with velocity, like a real piano's.
            let loudness = 0.12 + 0.88 * pow(velocity, 1.6)
            return Voice(midi: midi, phases: [], increments: [], gains: [], decayPerSample: 1, level: loudness,
                         releasePerSample: Float(exp(-1 / (0.05 * sampleRate))), attack: 1, recording: recording)
        }
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
