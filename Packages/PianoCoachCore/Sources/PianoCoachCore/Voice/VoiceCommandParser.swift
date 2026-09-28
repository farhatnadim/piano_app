import Foundation

/// Turns speech-recogniser transcripts ("okay um can you go slower please") into `VoiceCommand`s.
///
/// Matching is done on whole words after normalisation (lowercase, hyphens and punctuation become
/// spaces, apostrophes are dropped so "let's" reads "lets", "%" reads "percent").
///
/// Speech recognisers deliver growing partial transcripts, so the newest words matter most: among all
/// phrases found, the parser returns the one that **ends latest** in the utterance. When two phrases end
/// on the same word the longer one wins ("wait for me" beats "wait", "stop looping" beats "stop",
/// "start again" beats "again").
public struct VoiceCommandParser: Sendable {
    /// When true, only the words after the last wake word are considered, and an utterance without a
    /// wake word yields nil. A wake word that is itself part of a command ("coach off",
    /// "turn off the coach") counts as addressing the coach, and the command is kept.
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
    public static let contextualStrings: [String] = {
        var list = [
            // play / pause
            "play", "pause", "stop", "keep going", "let's go", "wait", "hold on",
            // speed
            "slower", "slow down", "too fast", "faster", "speed up", "too slow",
            "normal speed", "half speed", "quarter speed", "three quarter speed", "fifty percent", "seventy five percent",
            // sheet music
            "show the music", "show me the music", "show the notes", "sheet music",
            "hide the music", "hide the notes", "no music",
            // coach modes
            "follow me", "follow along", "wait for me", "coach off", "stop following", "free play",
            // navigation
            "go back", "rewind", "back up", "go forward", "skip ahead",
            "again", "one more time", "do it again", "try again", "repeat",
            "from the top", "start over", "from the beginning", "start again", "restart",
            "go to measure", "measure", "bar",
            // loops
            "loop this", "loop this part", "practice this part", "stop looping", "stop the loop", "loop off", "no loop",
            // sound
            "sound on", "sound off", "mute", "unmute", "quiet",
            // help
            "help", "what can I say",
            // wake words
            "hey coach", "piano coach",
        ]
        let numberWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                           "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                           "eighteen", "nineteen", "twenty"]
        for word in numberWords where list.count < 100 {
            list.append("measure \(word)")
        }
        return list
    }()

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
        /// ("go" in "go to measure …" is not "play").
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

        let dynamicPriority = phrases.count
        matches += measureMatches(in: tokens, priority: dynamicPriority)
        matches += speedMatches(in: tokens, priority: dynamicPriority + 1)
        return matches
    }

    private static let measureKeywords: Set<String> = ["measure", "measures", "bar", "bars", "major"]
    private static let ordinalMeasureKeywords: Set<String> = ["measure", "bar"]

    /// "measure 12", "go to bar twelve", "measure to" (-> 2), "bar for" (-> 4), "the third measure".
    private static func measureMatches(in tokens: [String], priority: Int) -> [Match] {
        var matches: [Match] = []
        let n = tokens.count
        for i in 0..<n where measureKeywords.contains(tokens[i]) {
            // Keyword followed by a number ("measure number 5" is fine too).
            var j = i + 1
            if j < n, tokens[j] == "number" { j += 1 }
            if let p = NumberWords.scan(tokens, from: j, allowHomophones: true) {
                var start = i
                if i >= 2, tokens[i - 2] == "go", tokens[i - 1] == "to" { start = i - 2 }
                matches.append(Match(command: .goToMeasure(p.value), start: start, end: j + p.consumed, priority: priority))
            }
            // Ordinal before the keyword: "the third bar", "12th measure".
            if ordinalMeasureKeywords.contains(tokens[i]) {
                for s in max(0, i - 5)..<i {
                    if let p = NumberWords.scan(tokens, from: s, allowHomophones: false),
                       p.isOrdinal, s + p.consumed == i {
                        matches.append(Match(command: .goToMeasure(p.value), start: s, end: i + 1, priority: priority))
                        break
                    }
                }
            }
        }
        return matches
    }

    /// "speed 75", "speed fifty percent", "75 percent", "60 percent speed", "speed 0.5".
    private static func speedMatches(in tokens: [String], priority: Int) -> [Match] {
        var matches: [Match] = []
        let n = tokens.count

        // "speed N": N <= 2 is a multiplier ("speed one" = 1x), larger N is a percentage.
        for i in 0..<n where tokens[i] == "speed" && i + 1 < n {
            guard let number = numberValue(tokens, at: i + 1) else { continue }
            var end = i + 1 + number.consumed
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
            (.pause, ["pause", "stop", "wait", "hold on", "hang on", "freeze"]),
            (.slower, ["slower", "slow down", "too fast", "slow"]),
            (.faster, ["faster", "speed up", "speed it up", "too slow", "quicker", "hurry up"]),
            (.normalSpeed, ["normal speed", "regular speed", "full speed", "original speed", "normal"]),
            (.setSpeed(0.5), ["half speed"]),
            (.setSpeed(0.25), ["quarter speed"]),
            (.setSpeed(0.75), ["three quarter speed", "three quarters speed"]),
            (.setSpeed(2.0), ["double speed"]),
            (.showMusic, ["show the music", "show music", "show the notes", "show notes", "show the sheet",
                          "show sheet music", "show the sheet music", "show me the music", "show me the notes",
                          "show me the sheet music", "see the music", "sheet music", "music please", "open the music"]),
            (.hideMusic, ["hide the music", "hide music", "hide the notes", "hide notes", "close the music",
                          "no music", "no music please", "hide the sheet", "hide the sheet music", "hide sheet music",
                          "close the sheet music"]),
            (.followMe, ["follow me", "follow along", "follow mode"]),
            (.waitForMe, ["wait for me", "wait mode"]),
            (.coachOff, ["coach off", "stop following", "free play", "turn off the coach", "turn the coach off"]),
            (.goBack, ["go back", "back", "rewind", "back up", "go backwards"]),
            (.goForward, ["go forward", "skip ahead", "skip", "forward"]),
            (.again, ["again", "one more time", "repeat", "do it again", "try again"]),
            (.restart, ["from the top", "start over", "from the beginning", "the beginning", "restart", "start again",
                        "from the start", "back to the start"]),
            (.loopThis, ["loop this", "loop", "practice this part", "repeat this part", "loop this part"]),
            (.stopLoop, ["stop loop", "stop looping", "no loop", "loop off", "end loop", "stop the loop", "stop repeating",
                         "no more loop", "no more looping"]),
            (.soundOn, ["sound on", "unmute", "turn on the sound", "turn the sound on", "sound back on", "louder", "turn it up"]),
            (.soundOff, ["sound off", "mute", "turn off the sound", "turn the sound off", "quiet", "silence"]),
            (.help, ["help", "what can i say", "what can you do", "what do i say"]),
        ]
        let notFollowedBy: [String: Set<String>] = [
            // "go to measure …" / "let's go to the beginning": wait for the destination instead of playing.
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
