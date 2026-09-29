#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// Reads the app's piano recordings — one file per key, named `Piano-060.mp3` for middle C — into
/// `PianoSample`s for `PianoSynthesizer.loadSamples`.
public enum PianoSampleLoader {
    public enum LoadError: Error {
        case unreadable
    }

    /// The file name of a key's recording.
    public static func fileName(for midi: Int) -> String {
        String(format: "Piano-%03d.mp3", midi)
    }

    /// The recordings bundled with the app (keys without a file are skipped).
    public static func load(from bundle: Bundle) -> [PianoSample] {
        (Pitch.lowestPianoMIDI...Pitch.highestPianoMIDI).compactMap { midi in
            let name = (fileName(for: midi) as NSString).deletingPathExtension
            guard let url = bundle.url(forResource: name, withExtension: "mp3") else { return nil }
            return try? sample(midi: midi, url: url)
        }
    }

    /// The recordings in a folder (keys without a file are skipped).
    public static func load(from directory: URL) -> [PianoSample] {
        (Pitch.lowestPianoMIDI...Pitch.highestPianoMIDI).compactMap { midi in
            try? sample(midi: midi, url: directory.appendingPathComponent(fileName(for: midi)))
        }
    }

    /// One recording as mono samples, trimmed so the note starts at once (compressed files begin with a
    /// few milliseconds of silence) and faded out at the end so it never clicks.
    public static func sample(midi: Int, url: URL) throws -> PianoSample {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw LoadError.unreadable
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { throw LoadError.unreadable }
        let count = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        let scale = 1 / Float(channels)
        for c in 0..<channels {
            for i in 0..<count { mono[i] += data[c][i] * scale }
        }
        let peak = mono.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else { throw LoadError.unreadable }
        let rate = format.sampleRate
        // Start 1 ms before the attack; end where the sound has died away.
        let attack = mono.firstIndex { abs($0) > peak * 0.01 } ?? 0
        let start = max(0, attack - Int(rate * 0.001))
        let end = (mono.lastIndex { abs($0) > peak * 0.001 } ?? count - 1) + 1
        var trimmed = Array(mono[start..<max(start + 1, end)])
        let fade = min(trimmed.count, Int(rate * 0.02))
        for k in 0..<fade {
            trimmed[trimmed.count - fade + k] *= Float(fade - k) / Float(fade)
        }
        return PianoSample(midi: midi, sampleRate: rate, samples: trimmed)
    }
}
#endif
