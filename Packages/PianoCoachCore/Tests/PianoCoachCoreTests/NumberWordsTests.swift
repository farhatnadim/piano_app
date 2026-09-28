import XCTest
@testable import PianoCoachCore

final class NumberWordsTests: XCTestCase {

    private func parse(_ text: String, from start: Int = 0, homophones: Bool = false) -> (value: Int, consumed: Int)? {
        let tokens = text.split(separator: " ").map(String.init)
        return NumberWords.parse(tokens: tokens, from: start, allowHomophones: homophones)
    }

    private func assertParse(_ text: String, _ value: Int, _ consumed: Int, homophones: Bool = false,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let p = parse(text, homophones: homophones) else {
            return XCTFail("no number in \"\(text)\"", file: file, line: line)
        }
        XCTAssertEqual(p.value, value, "value of \"\(text)\"", file: file, line: line)
        XCTAssertEqual(p.consumed, consumed, "consumed of \"\(text)\"", file: file, line: line)
    }

    func testDigits() {
        assertParse("12", 12, 1)
        assertParse("0", 0, 1)
        assertParse("12th", 12, 1)
        assertParse("3rd", 3, 1)
        assertParse("1st", 1, 1)
        assertParse("22nd", 22, 1)
        assertParse("12 please", 12, 1)
        XCTAssertNil(parse("th"))
        XCTAssertNil(parse("12abc"))
        XCTAssertNil(parse("99999999999999999999999"))
    }

    func testCardinalWords() {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                     "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                     "eighteen", "nineteen"]
        for (value, word) in words.enumerated() {
            assertParse(word, value, 1)
        }
        let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
                    "seventy": 70, "eighty": 80, "ninety": 90]
        for (word, value) in tens {
            assertParse(word, value, 1)
        }
    }

    func testCompounds() {
        assertParse("twenty one", 21, 2)
        assertParse("ninety nine", 99, 2)
        assertParse("thirty four bars", 34, 2)
        assertParse("twenty-one", 21, 1)
        assertParse("Twenty Three", 23, 2)
        // "twenty zero" is not a compound.
        assertParse("twenty zero", 20, 1)
        // Teens and units do not compound.
        assertParse("twelve one", 12, 1)
        assertParse("one two", 1, 1)
    }

    func testHundreds() {
        assertParse("a hundred", 100, 2)
        assertParse("hundred", 100, 1)
        assertParse("one hundred", 100, 2)
        assertParse("two hundred", 200, 2)
        assertParse("one hundred and five", 105, 4)
        assertParse("one hundred five", 105, 3)
        assertParse("three hundred twenty one", 321, 4)
        assertParse("a hundred and twenty", 120, 4)
        assertParse("2 hundred", 200, 2)
        // A dangling "and" is not consumed.
        assertParse("one hundred and then", 100, 2)
        assertParse("one-hundred-and-five", 105, 1)
        // "a" alone is not a number.
        XCTAssertNil(parse("a"))
        XCTAssertNil(parse("a few"))
    }

    func testOrdinals() {
        let ordinals = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
                        "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12,
                        "thirteenth": 13, "nineteenth": 19, "twentieth": 20, "thirtieth": 30, "ninetieth": 90]
        for (word, value) in ordinals {
            assertParse(word, value, 1)
        }
        assertParse("twenty first", 21, 2)
        assertParse("thirty second", 32, 2)
        assertParse("hundredth", 100, 1)
        assertParse("one hundredth", 100, 2)
        assertParse("one hundred and first", 101, 4)
    }

    func testOrdinalFlag() {
        XCTAssertEqual(NumberWords.scan(["third"], from: 0, allowHomophones: false)?.isOrdinal, true)
        XCTAssertEqual(NumberWords.scan(["3rd"], from: 0, allowHomophones: false)?.isOrdinal, true)
        XCTAssertEqual(NumberWords.scan(["twenty", "first"], from: 0, allowHomophones: false)?.isOrdinal, true)
        XCTAssertEqual(NumberWords.scan(["three"], from: 0, allowHomophones: false)?.isOrdinal, false)
        XCTAssertEqual(NumberWords.scan(["twenty"], from: 0, allowHomophones: false)?.isOrdinal, false)
    }

    func testHomophonesOnlyWhenAllowed() {
        for word in ["to", "too", "for", "fore", "won", "ate"] {
            XCTAssertNil(parse(word), word)
        }
        assertParse("to", 2, 1, homophones: true)
        assertParse("too", 2, 1, homophones: true)
        assertParse("two", 2, 1, homophones: false)
        assertParse("for", 4, 1, homophones: true)
        assertParse("four", 4, 1, homophones: false)
        assertParse("won", 1, 1, homophones: true)
        assertParse("ate", 8, 1, homophones: true)
        // Compound with a homophone unit.
        assertParse("twenty for", 24, 2, homophones: true)
        assertParse("twenty for", 20, 1, homophones: false)
    }

    func testParseFromOffset() {
        let tokens = ["go", "to", "measure", "four"]
        XCTAssertNil(NumberWords.parse(tokens: tokens, from: 0))
        XCTAssertNil(NumberWords.parse(tokens: tokens, from: 1))
        XCTAssertEqual(NumberWords.parse(tokens: tokens, from: 1, allowHomophones: true)?.value, 2)
        XCTAssertEqual(NumberWords.parse(tokens: tokens, from: 3)?.value, 4)
        XCTAssertNil(NumberWords.parse(tokens: tokens, from: 4))
        XCTAssertNil(NumberWords.parse(tokens: tokens, from: -1))
        XCTAssertNil(NumberWords.parse(tokens: [], from: 0))
    }

    func testFirstNumber() {
        XCTAssertEqual(NumberWords.firstNumber(in: "go to measure twelve"), 12)
        XCTAssertEqual(NumberWords.firstNumber(in: "go to measure four"), 4)
        XCTAssertEqual(NumberWords.firstNumber(in: "bar twenty-one please"), 21)
        XCTAssertEqual(NumberWords.firstNumber(in: "Measure 12."), 12)
        XCTAssertEqual(NumberWords.firstNumber(in: "the 3rd time"), 3)
        XCTAssertEqual(NumberWords.firstNumber(in: "about a hundred and five"), 105)
        XCTAssertEqual(NumberWords.firstNumber(in: "1,000 times"), 1000)
        XCTAssertEqual(NumberWords.firstNumber(in: "3.5"), 3)
        XCTAssertEqual(NumberWords.firstNumber(in: "fifty%"), 50)
        XCTAssertNil(NumberWords.firstNumber(in: "I want to go for a walk"))
        XCTAssertNil(NumberWords.firstNumber(in: ""))
    }

    func testTokenize() {
        XCTAssertEqual(NumberWords.tokenize("Let's go, NOW!"), ["lets", "go", "now"])
        XCTAssertEqual(NumberWords.tokenize("twenty-one"), ["twenty", "one"])
        XCTAssertEqual(NumberWords.tokenize("50% speed"), ["50", "percent", "speed"])
        XCTAssertEqual(NumberWords.tokenize("speed 0.5", keepDecimalPoints: true), ["speed", "0.5"])
        XCTAssertEqual(NumberWords.tokenize("speed 0.5"), ["speed", "0", "5"])
        XCTAssertEqual(NumberWords.tokenize("end. Next"), ["end", "next"])
        XCTAssertEqual(NumberWords.tokenize("it\u{2019}s   ok"), ["its", "ok"])
    }
}
