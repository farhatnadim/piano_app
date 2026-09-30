import XCTest
@testable import PianoCoachCore

final class VoiceCommandParserTests: XCTestCase {
    private let parser = VoiceCommandParser()

    private func assertCommand(_ utterance: String, _ expected: VoiceCommand?, parser: VoiceCommandParser? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
        let result = (parser ?? self.parser).parse(utterance)
        XCTAssertEqual(result, expected, "\"\(utterance)\"", file: file, line: line)
    }

    // MARK: - Phrase table

    func testPlayAndPause() {
        for text in ["play", "start", "go", "continue", "resume", "keep going", "let's go", "lets go", "Play!"] {
            assertCommand(text, .play)
        }
        for text in ["pause", "stop", "wait", "hold on", "hang on", "freeze", "STOP.", "stop stop stop"] {
            assertCommand(text, .pause)
        }
    }

    func testSpeedCommands() {
        for text in ["slower", "slow down", "too fast", "slow", "it's too fast", "reduce speed", "reduce the speed",
                     "decrease the speed", "lower the speed", "please reduce the speed"] {
            assertCommand(text, .slower)
        }
        for text in ["faster", "speed up", "too slow", "quicker", "it's too slow", "increase speed",
                     "increase the speed", "more speed", "can you increase the speed"] {
            assertCommand(text, .faster)
        }
        for text in ["normal speed", "regular speed", "full speed", "normal"] {
            assertCommand(text, .normalSpeed)
        }
    }

    func testSetSpeed() {
        assertCommand("half speed", .setSpeed(0.5))
        assertCommand("quarter speed", .setSpeed(0.25))
        assertCommand("three quarter speed", .setSpeed(0.75))
        assertCommand("three quarters speed", .setSpeed(0.75))
        assertCommand("three-quarter speed", .setSpeed(0.75))
        assertCommand("speed 75", .setSpeed(0.75))
        assertCommand("speed seventy five", .setSpeed(0.75))
        assertCommand("speed fifty percent", .setSpeed(0.5))
        assertCommand("75 percent", .setSpeed(0.75))
        assertCommand("seventy five percent", .setSpeed(0.75))
        assertCommand("sixty percent speed", .setSpeed(0.6))
        assertCommand("play at 50% speed", .setSpeed(0.5))
        assertCommand("fifty per cent", .setSpeed(0.5))
        assertCommand("a hundred percent", .setSpeed(1.0))
        // Clamped to 0.25...2.
        assertCommand("speed 10", .setSpeed(0.25))
        assertCommand("five percent", .setSpeed(0.25))
        assertCommand("speed 300", .setSpeed(2.0))
        assertCommand("three hundred percent", .setSpeed(2.0))
        // Small numbers after "speed" are multipliers.
        assertCommand("speed one", .setSpeed(1.0))
        assertCommand("speed 2", .setSpeed(2.0))
        assertCommand("speed 0.5", .setSpeed(0.5))
        assertCommand("speed 2 percent", .setSpeed(0.25))
        // "speed up" is not a number.
        assertCommand("speed up", .faster)
        assertCommand("speed up to 75 percent", .setSpeed(0.75))
    }

    func testViewCommands() {
        for text in ["show the notes", "show notes", "show me the notes", "show the music", "sheet music",
                     "can you show me the notes", "show the staff"] {
            assertCommand(text, .showNotes)
        }
        for text in ["show the keys", "show keys", "show the keyboard", "show the piano", "hide the notes",
                     "no music"] {
            assertCommand(text, .showKeys)
        }
    }

    func testListenAndHands() {
        for text in ["listen", "play the song", "play it for me", "show me", "show me how", "let me hear", "watch"] {
            assertCommand(text, .listen)
        }
        assertCommand("right hand", .hands(.right))
        assertCommand("just the right hand", .hands(.right))
        assertCommand("left hand only", .hands(.left))
        assertCommand("both hands", .hands(.both))
        assertCommand("two hands", .hands(.both))
    }

    func testAgainAndSound() {
        for text in ["again", "one more time", "repeat", "do it again", "try again", "play it again", "play again",
                     "from the top", "start over", "from the beginning", "restart", "start again",
                     "let's start from the top", "back to the start"] {
            assertCommand(text, .again)
        }
        for text in ["sound on", "unmute", "turn on the sound", "turn the sound on", "louder", "turn the sound back on"] {
            assertCommand(text, .soundOn)
        }
        for text in ["sound off", "mute", "turn off the sound", "turn the sound off", "quiet", "silence"] {
            assertCommand(text, .soundOff)
        }
        for text in ["help", "what can I say", "What can you do?"] {
            assertCommand(text, .help)
        }
    }

    func testWordsThatUsedToBeCommandsAreIgnored() {
        assertCommand("measure 12", nil)
        assertCommand("follow me", nil)
        assertCommand("loop this", nil)
        assertCommand("go to", nil)
        assertCommand("let's go to", nil)
        assertCommand("g major", nil)
        assertCommand("play the g major scale", .play)
    }

    // MARK: - Ends-latest and tie-breaking

    func testLatestEndingCommandWins() {
        assertCommand("stop no wait play", .play)
        assertCommand("play no stop", .pause)
        assertCommand("I want to play it again", .again)
        assertCommand("faster no slower", .slower)
        assertCommand("play from the top", .again)
        assertCommand("show the notes and play", .play)
    }

    func testLongestPhraseBreaksTies() {
        assertCommand("start again", .again)
        assertCommand("too slow", .faster)
        assertCommand("play the song", .listen)
        assertCommand("show me the notes", .showNotes)
        assertCommand("three quarter speed", .setSpeed(0.75))
        assertCommand("right hand only", .hands(.right))
    }

    // MARK: - Realistic kid speech

    func testKidSpeechTranscripts() {
        assertCommand("okay um can you go slower please", .slower)
        assertCommand("show me the music", .showNotes)
        assertCommand("show me the notes please", .showNotes)
        assertCommand("um um that was too fast", .slower)
        assertCommand("can we do it again", .again)
        assertCommand("uh can you make it faster", .faster)
        assertCommand("I messed up can I start over", .again)
        assertCommand("Hold on, hold on!", .pause)
        assertCommand("OK let's go", .play)
        assertCommand("can you play the song for me", .listen)
        assertCommand("I want to do the right hand", .hands(.right))
    }

    func testNegationsAndExtras() {
        assertCommand("don't stop", .play)
        assertCommand("don't stop playing", .play)
        assertCommand("turn it up", .soundOn)
        assertCommand("stop the music", .pause)
        assertCommand("play at double speed", .setSpeed(2.0))
        assertCommand("back to the start", .again)
    }

    func testNoCommand() {
        assertCommand("", nil)
        assertCommand("   ", nil)
        assertCommand("I like this song", nil)
        assertCommand("my cat is called fluffy", nil)
        assertCommand("um", nil)
        assertCommand("?!", nil)
    }

    func testPartialTranscriptsGrow() {
        // Each partial result is parsed on its own; the newest command wins.
        assertCommand("okay", nil)
        assertCommand("okay stop", .pause)
        assertCommand("okay stop and", .pause)
        assertCommand("okay stop and play", .play)
    }

    // MARK: - Wake word

    func testWakeWordRequired() {
        let p = VoiceCommandParser(requireWakeWord: true)
        assertCommand("hey coach faster", .faster, parser: p)
        assertCommand("Hey, Coach! Faster.", .faster, parser: p)
        assertCommand("faster", nil, parser: p)
        assertCommand("hey coach", nil, parser: p)
        assertCommand("piano coach reduce the speed", .slower, parser: p)
        assertCommand("hey piano play", .play, parser: p)
        assertCommand("coach slower", .slower, parser: p)
    }

    func testWakeWordOnlyTextAfterLastOccurrenceCounts() {
        let p = VoiceCommandParser(requireWakeWord: true)
        // The command before the latest wake word is not repeated.
        assertCommand("hey coach faster hey coach", nil, parser: p)
        assertCommand("play hey coach stop", .pause, parser: p)
        assertCommand("stop hey coach", nil, parser: p)
    }

    func testCustomWakeWords() {
        let p = VoiceCommandParser(requireWakeWord: true, wakeWords: ["Hey Maestro"])
        assertCommand("hey maestro pause", .pause, parser: p)
        assertCommand("hey coach pause", nil, parser: p)
        let none = VoiceCommandParser(requireWakeWord: true, wakeWords: [])
        assertCommand("pause", nil, parser: none)
        // Without requireWakeWord, wake words are ignored.
        assertCommand("hey coach pause", .pause)
    }

    // MARK: - Contextual strings

    func testContextualStrings() {
        let strings = VoiceCommandParser.contextualStrings
        XCTAssertLessThanOrEqual(strings.count, 100)
        XCTAssertEqual(Set(strings).count, strings.count, "duplicates")
        XCTAssertTrue(strings.contains("reduce speed"))
        XCTAssertTrue(strings.contains("increase speed"))
        // Every string except the wake words is a command on its own.
        let notCommands: Set<String> = ["hey coach", "piano coach"]
        for s in strings where !notCommands.contains(s) {
            XCTAssertNotNil(parser.parse(s), s)
        }
        for s in notCommands {
            XCTAssertNil(parser.parse(s), s)
        }
    }

    func testSpeedWithToAtOf() {
        assertCommand("set the speed to 60", .setSpeed(0.6))
        assertCommand("change speed to seventy five", .setSpeed(0.75))
        assertCommand("speed at 50 percent", .setSpeed(0.5))
        assertCommand("play at a speed of 80", .setSpeed(0.8))
        assertCommand("reduce the speed to fifty percent", .setSpeed(0.5))
        assertCommand("speed to one", .setSpeed(1.0))
        // Without a number it is still just a speed change.
        assertCommand("reduce the speed to", .slower)
    }

    func testParserIsValueTypeAndConfigurable() {
        var p = VoiceCommandParser()
        XCTAssertFalse(p.requireWakeWord)
        XCTAssertEqual(p.wakeWords, ["hey coach", "coach", "hey piano", "piano coach"])
        p.requireWakeWord = true
        XCTAssertNil(p.parse("play"))
        XCTAssertEqual(p.parse("coach play"), .play)
    }
}
