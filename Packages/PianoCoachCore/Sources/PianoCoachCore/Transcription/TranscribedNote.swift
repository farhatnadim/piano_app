import Foundation

/// A note heard in a recording: its pitch, when it starts and ends (seconds from the start of the
/// recording) and how strongly it sounded.
public struct TranscribedNote: Codable, Hashable, Sendable {
    public var midi: Int
    public var start: Double
    public var end: Double
    /// 0...1: how strongly the note sounded (the transcriber's average activation), used as loudness.
    public var amplitude: Double

    public init(midi: Int, start: Double, end: Double, amplitude: Double) {
        self.midi = midi
        self.start = start
        self.end = end
        self.amplitude = amplitude
    }

    public var duration: Double { end - start }
}
