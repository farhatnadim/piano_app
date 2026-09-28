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
        for text in ["slower", "slow down", "too fast", "slow", "it's too fast"] {
            assertCommand(text, .slower)
        }
        for text in ["faster", "speed up", "too slow", "quicker", "it's too slow"] {
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

    func testMusicCommands() {
        for text in ["show the music", "show music", "show the notes", "show notes", "show the sheet",
                     "show sheet music", "show the sheet music", "sheet music", "music please", "open the music",
                     "show me the music", "show me the notes", "can you show me the notes"] {
            assertCommand(text, .showMusic)
        }
        for text in ["hide the music", "hide music", "hide the notes", "hide notes", "close the music",
                     "no music", "hide the sheet", "hide the sheet music", "no music please"] {
            assertCommand(text, .hideMusic)
        }
    }

    func testCoachModes() {
        for text in ["follow me", "follow along", "follow mode"] {
            assertCommand(text, .followMe)
        }
        for text in ["wait for me", "wait mode", "wait wait for me"] {
            assertCommand(text, .waitForMe)
        }
        for text in ["coach off", "stop following", "free play", "turn off the coach"] {
            assertCommand(text, .coachOff)
        }
    }

    func testNavigation() {
        for text in ["go back", "back", "rewind", "back up", "go backwards", "back a bit"] {
            assertCommand(text, .goBack)
        }
        for text in ["go forward", "skip ahead", "skip", "forward"] {
            assertCommand(text, .goForward)
        }
        for text in ["again", "one more time", "repeat", "do it again", "try again", "play it again"] {
            assertCommand(text, .again)
        }
        for text in ["from the top", "start over", "from the beginning", "the beginning", "restart",
                     "start again", "let's start from the top", "go back to the beginning"] {
            assertCommand(text, .restart)
        }
    }

    func testLoopAndSound() {
        for text in ["loop this", "loop", "practice this part", "repeat this part", "loop this part"] {
            assertCommand(text, .loopThis)
        }
        for text in ["stop loop", "stop looping", "no loop", "loop off", "end loop", "stop the loop"] {
            assertCommand(text, .stopLoop)
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

    // MARK: - Measures

    func testGoToMeasure() {
        assertCommand("measure 12", .goToMeasure(12))
        assertCommand("go to measure twelve", .goToMeasure(12))
        assertCommand("go to measure four", .goToMeasure(4))
        assertCommand("bar 3", .goToMeasure(3))
        assertCommand("bars twenty one", .goToMeasure(21))
        assertCommand("measures 5", .goToMeasure(5))
        assertCommand("go to major 7", .goToMeasure(7))
        assertCommand("measure number nine", .goToMeasure(9))
        assertCommand("measure twenty-one", .goToMeasure(21))
        assertCommand("measure one hundred and five", .goToMeasure(105))
        assertCommand("play measure five", .goToMeasure(5))
        assertCommand("go back to measure 3", .goToMeasure(3))
        assertCommand("Measure 12.", .goToMeasure(12))
    }

    func testGoToMeasureHomophones() {
        assertCommand("measure to", .goToMeasure(2))
        assertCommand("bar for", .goToMeasure(4))
        assertCommand("go to bar too", .goToMeasure(2))
        assertCommand("measure won", .goToMeasure(1))
        assertCommand("measure ate", .goToMeasure(8))
    }

    func testOrdinalMeasure() {
        assertCommand("go to the third bar", .goToMeasure(3))
        assertCommand("the 12th measure", .goToMeasure(12))
        assertCommand("twenty first measure", .goToMeasure(21))
        // Cardinals before the keyword are a count, not a position.
        assertCommand("two bars", nil)
    }

    func testMeasureKeywordWithoutNumberIsNotACommand() {
        assertCommand("measure", nil)
        assertCommand("the measure", nil)
        assertCommand("g major", nil)
        assertCommand("play the g major scale", .play)
        // Partial transcript: the number has not arrived yet, so "go" must not mean "play".
        assertCommand("go to measure", nil)
        assertCommand("go to", nil)
        assertCommand("let's go to", nil)
    }

    // MARK: - Ends-latest and tie-breaking

    func testLatestEndingCommandWins() {
        assertCommand("stop no wait play", .play)
        assertCommand("play no stop", .pause)
        assertCommand("I want to play it again", .again)
        assertCommand("faster no slower", .slower)
        assertCommand("go to measure four and then play", .play)
        assertCommand("play from the top", .restart)
        assertCommand("show the music and loop this", .loopThis)
    }

    func testLongestPhraseBreaksTies() {
        assertCommand("wait for me", .waitForMe)
        assertCommand("start again", .restart)
        assertCommand("stop looping", .stopLoop)
        assertCommand("stop following", .coachOff)
        assertCommand("too slow", .faster)
        assertCommand("free play", .coachOff)
        assertCommand("repeat this part", .loopThis)
        assertCommand("hide the sheet music", .hideMusic)
        assertCommand("three quarter speed", .setSpeed(0.75))
    }

    // MARK: - Realistic kid speech

    func testKidSpeechTranscripts() {
        assertCommand("okay um can you go slower please", .slower)
        assertCommand("wait wait for me", .waitForMe)
        assertCommand("go to measure twelve", .goToMeasure(12))
        assertCommand("bar for", .goToMeasure(4))
        assertCommand("stop looping", .stopLoop)
        assertCommand("show me the music", .showMusic)
        assertCommand("show me the notes please", .showMusic)
        assertCommand("um um that was too fast", .slower)
        assertCommand("can we do it again", .again)
        assertCommand("uh can you make it faster", .faster)
        assertCommand("I messed up can I start over", .restart)
        assertCommand("Hold on, hold on!", .pause)
        assertCommand("OK let's go", .play)
        assertCommand("can you follow me", .followMe)
    }

    func testNegationsAndExtras() {
        assertCommand("don't stop", .play)
        assertCommand("don't stop playing", .play)
        assertCommand("no more loop", .stopLoop)
        assertCommand("no more looping please", .stopLoop)
        assertCommand("turn it up", .soundOn)
        assertCommand("stop the music", .pause)
        assertCommand("I can't see the music", .showMusic)
        assertCommand("play at double speed", .setSpeed(2.0))
        assertCommand("back to the start", .restart)
        assertCommand("start from measure five", .goToMeasure(5))
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
        assertCommand("okay stop looping", .stopLoop)
        assertCommand("okay stop looping and play", .play)
    }

    // MARK: - Wake word

    func testWakeWordRequired() {
        let p = VoiceCommandParser(requireWakeWord: true)
        assertCommand("hey coach faster", .faster, parser: p)
        assertCommand("Hey, Coach! Faster.", .faster, parser: p)
        assertCommand("faster", nil, parser: p)
        assertCommand("hey coach", nil, parser: p)
        assertCommand("piano coach go to measure 5", .goToMeasure(5), parser: p)
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

    func testWakeWordInsideCommand() {
        let p = VoiceCommandParser(requireWakeWord: true)
        assertCommand("hey coach coach off", .coachOff, parser: p)
        assertCommand("coach off", .coachOff, parser: p)
        assertCommand("hey coach turn off the coach", .coachOff, parser: p)
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
        XCTAssertTrue(strings.contains("measure twenty"))
        XCTAssertTrue(strings.contains("wait for me"))
        // Every string except the wake words and bare keywords is a command on its own.
        let notCommands: Set<String> = ["hey coach", "piano coach", "go to measure", "measure", "bar"]
        for s in strings where !notCommands.contains(s) {
            XCTAssertNotNil(parser.parse(s), s)
        }
        for s in notCommands {
            XCTAssertNil(parser.parse(s), s)
        }
        XCTAssertEqual(parser.parse("measure seventeen"), .goToMeasure(17))
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
