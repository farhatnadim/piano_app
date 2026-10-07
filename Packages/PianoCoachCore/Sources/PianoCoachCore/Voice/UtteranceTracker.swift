import Foundation

/// Splits a speech recogniser's growing transcript into utterances at the pauses between them.
///
/// A recognition task keeps adding words for as long as it runs, so after a while its transcript holds
/// everything said in the room. The tracker notes when each word first arrived; the current utterance is
/// the words since the last pause longer than `pause`. Words the recogniser revises keep their arrival time.
public struct UtteranceTracker: Sendable {
    /// Seconds of silence between words that separate two utterances.
    public var pause: Double

    private var words: [String] = []
    private var arrivals: [Double] = []

    public init(pause: Double = 0.7) {
        self.pause = pause
    }

    /// Forgets everything heard (a new recognition task starts from an empty transcript).
    public mutating func reset() {
        words = []
        arrivals = []
    }

    /// Takes the whole transcript so far, at `time` (seconds), and returns the current utterance.
    public mutating func update(_ transcript: String, at time: Double) -> String {
        let newWords = transcript.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        var common = 0
        while common < min(words.count, newWords.count), words[common] == newWords[common] { common += 1 }
        var newArrivals = Array(arrivals.prefix(common))
        for i in common..<newWords.count { newArrivals.append(i < arrivals.count ? arrivals[i] : time) }
        words = newWords
        arrivals = newArrivals
        var start = 0
        var i = words.count - 1
        while i > 0 {
            if arrivals[i] - arrivals[i - 1] > pause {
                start = i
                break
            }
            i -= 1
        }
        return words[start...].joined(separator: " ")
    }
}
