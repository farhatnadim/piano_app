import Foundation

/// Turns speech-recogniser transcripts ("okay um can you go slower please") into `VoiceCommand`s.
///
/// Matching is done on whole words after normalisation (lowercase, hyphens and punctuation become
/// spaces, apostrophes are dropped so "let's" reads "lets", "%" reads "percent").
///
/// Speech recognisers deliver growing partial transcripts, so the newest words matter most: among all
/// phrases found, the parser returns the one that **ends latest** in the utterance. When two phrases end
/// on the same word the longer one wins ("play the song" beats "play", "show me the notes" beats
/// "show me", "start again" beats "again").
public struct VoiceCommandParser: Sendable {
    /// When true, only the words after the last wake word are considered, and an utterance without a
    /// wake word yields nil. A wake word that is itself part of a command phrase counts as addressing the
    /// coach, and the command is kept.
    public var requireWakeWord: Bool
    /// Phrases that address the coach, e.g. "hey coach".
    public var wakeWords: [String]

    public init(requireWakeWord: Bool = false,
                wakeWords: [String] = ["hey coach", "coach", "hey piano", "piano coach"]) {
        self.requireWakeWord = requireWakeWord
        self.wakeWords = wakeWords
    }

    /// The command in `utterance`, or nil if there is none.
    public func parse(_ utterance: String) -> VoiceCommand? {
        let tokens = Self.normalizedTokens(utterance)
        guard !tokens.isEmpty else { return nil }
        guard requireWakeWord else { return Self.bestMatch(in: tokens)?.command }
        guard let cut = wakeWordCut(in: tokens) else { return nil }
        return Self.bestMatch(in: Array(tokens[cut...]))?.command
    }

    /// Canonical phrases (at most 100) to bias the speech recogniser towards,
    /// e.g. `SFSpeechAudioBufferRecognitionRequest.contextualStrings`.
    public static let contextualStrings: [String] = [
        // play / stop
        "play", "stop", "pause", "keep going", "let's go", "wait", "hold on",
        // speed
        "slower", "slow down", "too fast", "reduce speed", "reduce the speed", "decrease the speed",
        "faster", "speed up", "too slow", "increase speed", "increase the speed",
        "normal speed", "half speed", "quarter speed", "three quarter speed", "fifty percent", "seventy five percent",
        // listening and views
        "listen", "play the song", "show me", "show me how",
        "show the notes", "show me the notes", "show the keys", "show the keyboard",
        // hands
        "right hand", "left hand", "both hands",
        // again
        "again", "one more time", "do it again", "try again", "from the top", "start over", "from the beginning",
        // sound
        "sound on", "sound off", "mute", "unmute", "quiet",
        // help
        "help", "what can I say",
        // wake words
        "hey coach", "piano coach",
    ]

    // MARK: - Matching

    /// One phrase found in the token list: tokens `start..<end`.
    struct Match: Equatable, Sendable {
        var command: VoiceCommand
        var start: Int
        var end: Int
        /// Lower wins when end and length tie.
        var priority: Int
        var length: Int { end - start }
    }

    /// A fixed phrase of the command table.
    struct Phrase: Sendable {
        var tokens: [String]
        var command: VoiceCommand
        /// The phrase does not count when immediately followed by one of these words
        /// ("go" in "let's go to the beginning" is not "play").
        var notFollowedBy: Set<String>
    }

    static func normalizedTokens(_ text: String) -> [String] {
        NumberWords.tokenize(text, keepDecimalPoints: true)
    }

    /// The winning match: latest end, then longest, then earliest in the table.
    static func bestMatch(in tokens: [String]) -> Match? {
        var best: Match?
        for m in allMatches(in: tokens) {
            guard let b = best else { best = m; continue }
            if m.end != b.end {
                if m.end > b.end { best = m }
            } else if m.length != b.length {
                if m.length > b.length { best = m }
            } else if m.priority < b.priority {
                best = m
            }
        }
        return best
    }

    /// Every command phrase found anywhere in `tokens`.
    static func allMatches(in tokens: [String]) -> [Match] {
        var matches: [Match] = []
        let n = tokens.count

        // Fixed phrases.
        for (priority, phrase) in phrases.enumerated() {
            let len = phrase.tokens.count
            guard len > 0, len <= n else { continue }
            for i in 0...(n - len) where tokens[i] == phrase.tokens[0] {
                var ok = true
                for k in 1..<len where tokens[i + k] != phrase.tokens[k] {
                    ok = false
                    break
                }
                guard ok else { continue }
                if i + len < n, phrase.notFollowedBy.contains(tokens[i + len]) { continue }
                matches.append(Match(command: phrase.command, start: i, end: i + len, priority: priority))
            }
        }

        matches += speedMatches(in: tokens, priority: phrases.count)
        return matches
    }

    /// "speed 75", "speed fifty percent", "75 percent", "60 percent speed", "speed 0.5", "set the speed to 60".
    private static func speedMatches(in tokens: [String], priority: Int) -> [Match] {
        var matches: [Match] = []
        let n = tokens.count

        // "speed N": N <= 2 is a multiplier ("speed one" = 1x), larger N is a percentage.
        for i in 0..<n where tokens[i] == "speed" && i + 1 < n {
            // "speed to 60", "speed at 50 percent", "a speed of 75".
            let first = ["to", "at", "of"].contains(tokens[i + 1]) ? i + 2 : i + 1
            guard let number = numberValue(tokens, at: first) else { continue }
            var end = first + number.consumed
            var rate = number.value <= 2 ? number.value : number.value / 100
            let pl = percentLength(tokens, at: end)
            if pl > 0 {
                rate = number.value / 100
                end += pl
            }
            matches.append(Match(command: .setSpeed(clampSpeed(rate)), start: i, end: end, priority: priority))
        }

        // "N percent", optionally followed by "speed".
        for i in 0..<n {
            guard let number = numberValue(tokens, at: i) else { continue }
            let pl = percentLength(tokens, at: i + number.consumed)
            guard pl > 0 else { continue }
            var end = i + number.consumed + pl
            if end < n, tokens[end] == "speed" { end += 1 }
            matches.append(Match(command: .setSpeed(clampSpeed(number.value / 100)), start: i, end: end, priority: priority))
        }
        return matches
    }

    /// A decimal token ("0.5") or a spoken/digit integer.
    private static func numberValue(_ tokens: [String], at i: Int) -> (value: Double, consumed: Int)? {
        guard i < tokens.count else { return nil }
        let t = tokens[i]
        if t.contains("."), let d = Double(t), d.isFinite, t.allSatisfy({ $0 == "." || $0.isASCII && $0.isNumber }) {
            return (d, 1)
        }
        guard let p = NumberWords.scan(tokens, from: i, allowHomophones: false) else { return nil }
        return (Double(p.value), p.consumed)
    }

    /// Tokens used by "percent" / "per cent" at `i` (0 if absent).
    private static func percentLength(_ tokens: [String], at i: Int) -> Int {
        guard i < tokens.count else { return 0 }
        if tokens[i] == "percent" { return 1 }
        if tokens[i] == "per", i + 1 < tokens.count, tokens[i + 1] == "cent" { return 2 }
        return 0
    }

    private static func clampSpeed(_ rate: Double) -> Double {
        min(max(rate, 0.25), 2.0)
    }

    // MARK: - Wake words

    /// Index of the first token after the last wake word, or nil if there is no wake word.
    private func wakeWordCut(in tokens: [String]) -> Int? {
        let wakePhrases = wakeWords.map(Self.normalizedTokens).filter { !$0.isEmpty }
        guard !wakePhrases.isEmpty else { return nil }
        let n = tokens.count
        let commandMatches = Self.allMatches(in: tokens)
        var cut: Int?
        for wake in wakePhrases where wake.count <= n {
            for i in 0...(n - wake.count) where Array(tokens[i..<(i + wake.count)]) == wake {
                let end = i + wake.count
                // A wake word inside a command phrase ("coach off") keeps that whole phrase.
                let c = commandMatches.filter { $0.start < end && i < $0.end }.map(\.start).min() ?? end
                cut = max(cut ?? c, c)
            }
        }
        return cut
    }

    // MARK: - Phrase table

    static let phrases: [Phrase] = {
        let table: [(VoiceCommand, [String])] = [
            (.play, ["play", "start", "go", "continue", "resume", "keep going", "keep playing", "lets go", "unpause",
                     "dont stop", "do not stop", "dont pause"]),
            (.pause, ["pause", "stop", "wait", "hold on", "hang on", "freeze", "stop it", "stop please"]),
            (.slower, ["slower", "slow down", "too fast", "slow", "reduce speed", "reduce the speed", "decrease speed",
                       "decrease the speed", "lower the speed", "lower speed", "less speed", "slow it down"]),
            (.faster, ["faster", "speed up", "speed it up", "too slow", "quicker", "hurry up", "increase speed",
                       "increase the speed", "raise the speed", "more speed", "higher speed"]),
            (.normalSpeed, ["normal speed", "regular speed", "full speed", "original speed", "normal"]),
            (.setSpeed(0.5), ["half speed"]),
            (.setSpeed(0.25), ["quarter speed"]),
            (.setSpeed(0.75), ["three quarter speed", "three quarters speed"]),
            (.setSpeed(2.0), ["double speed"]),
            (.listen, ["listen", "play the song", "play it for me", "play the music", "show me", "show me how",
                       "let me hear", "let me listen", "demo", "watch"]),
            (.showNotes, ["show the notes", "show notes", "show me the notes", "show the music", "show music",
                          "show me the music", "sheet music", "show the sheet music", "show the staff", "notes view",
                          "read the notes"]),
            (.showKeys, ["show the keys", "show keys", "show me the keys", "show the keyboard", "show the piano",
                         "keys view", "hide the notes", "hide the music", "no music"]),
            (.hands(.right), ["right hand", "right hand only", "just the right hand", "only the right hand"]),
            (.hands(.left), ["left hand", "left hand only", "just the left hand", "only the left hand"]),
            (.hands(.both), ["both hands", "two hands", "all hands", "both"]),
            (.again, ["again", "one more time", "repeat", "do it again", "try again", "from the top", "start over",
                      "from the beginning", "the beginning", "restart", "start again", "from the start",
                      "back to the start", "play again", "play it again"]),
            (.soundOn, ["sound on", "unmute", "turn on the sound", "turn the sound on", "sound back on", "louder",
                        "turn it up"]),
            (.soundOff, ["sound off", "mute", "turn off the sound", "turn the sound off", "quiet", "silence"]),
            (.help, ["help", "what can i say", "what can you do", "what do i say"]),
        ]
        let notFollowedBy: [String: Set<String>] = [
            // "let's go to the beginning": wait for the destination instead of playing.
            "go": ["to"],
            "lets go": ["to"],
        ]
        return table.flatMap { command, texts in
            texts.map { text in
                Phrase(tokens: normalizedTokens(text), command: command, notFollowedBy: notFollowedBy[text] ?? [])
            }
        }
    }()
}
