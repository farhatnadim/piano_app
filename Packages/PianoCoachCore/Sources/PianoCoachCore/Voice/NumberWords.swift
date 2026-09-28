import Foundation

/// Reads spoken numbers out of speech-recogniser transcripts.
///
/// Understands digits (`"12"`, `"12th"`, `"3rd"`), cardinal words (`"zero"` ... `"ninety nine"`),
/// hyphenated or split compounds (`"twenty-one"`, `"twenty one"`), hundreds (`"a hundred"`,
/// `"one hundred and five"`, `"two hundred"`) and ordinals (`"first"` ... `"twelfth"`, `"twentieth"`,
/// `"twenty first"`, `"hundredth"`).
///
/// Homophones that recognisers often produce instead of number words (`"to"`/`"too"` -> 2,
/// `"for"`/`"fore"` -> 4, `"won"` -> 1, `"ate"` -> 8) are accepted only when explicitly requested, because in
/// ordinary speech they are almost always the everyday word ("go to measure four").
public enum NumberWords {

    /// Parses a number starting exactly at `tokens[start]` (homophones are not accepted).
    ///
    /// - Returns: the value and how many tokens it spans, or nil if no number starts there.
    public static func parse(tokens: [String], from start: Int) -> (value: Int, consumed: Int)? {
        parse(tokens: tokens, from: start, allowHomophones: false)
    }

    /// Parses a number starting exactly at `tokens[start]`.
    ///
    /// Tokens are compared case-insensitively. A token that still contains hyphens
    /// (`"twenty-one"`) is read as a whole. Parsing is greedy: `["twenty", "one"]` is 21, not 20.
    ///
    /// - Parameter allowHomophones: also read "to"/"too" as 2, "for"/"fore" as 4, "won" as 1 and "ate" as 8.
    /// - Returns: the value and how many tokens it spans, or nil if no number starts there.
    public static func parse(tokens: [String], from start: Int, allowHomophones: Bool) -> (value: Int, consumed: Int)? {
        guard let p = scan(tokens, from: start, allowHomophones: allowHomophones) else { return nil }
        return (p.value, p.consumed)
    }

    /// The first number in free text (homophones are not accepted), e.g. `"go to bar twenty-one"` -> 21.
    public static func firstNumber(in text: String) -> Int? {
        let tokens = tokenize(text)
        for i in tokens.indices {
            if let p = scan(tokens, from: i, allowHomophones: false) { return p.value }
        }
        return nil
    }

    // MARK: - Internal API (used by VoiceCommandParser)

    /// A parsed number plus whether it was spoken as an ordinal ("third", "3rd").
    struct Parsed: Equatable, Sendable {
        var value: Int
        var consumed: Int
        var isOrdinal: Bool
    }

    /// Like `parse(tokens:from:allowHomophones:)` but also reports whether the number was an ordinal.
    static func scan(_ tokens: [String], from start: Int, allowHomophones: Bool) -> Parsed? {
        guard start >= 0, start < tokens.count else { return nil }
        let first = tokens[start].lowercased()

        // A single token that still contains hyphens ("twenty-one", "one-hundred-and-five").
        if first.contains("-") {
            let parts = first.split(separator: "-").map(String.init)
            guard !parts.isEmpty,
                  let p = scan(parts, from: 0, allowHomophones: allowHomophones),
                  p.consumed == parts.count else { return nil }
            return Parsed(value: p.value, consumed: 1, isOrdinal: p.isOrdinal)
        }

        var i = start
        var hundreds: Int
        if let d = digitValue(first) {
            // "2 hundred" (rare, but some recognisers mix digits and words).
            guard !d.isOrdinal, (1...9).contains(d.value), start + 1 < tokens.count,
                  let hundredIsOrdinal = hundredWord(tokens[start + 1]) else {
                return Parsed(value: d.value, consumed: 1, isOrdinal: d.isOrdinal)
            }
            if hundredIsOrdinal { return Parsed(value: d.value * 100, consumed: 2, isOrdinal: true) }
            hundreds = d.value * 100
            i = start + 2
        } else if first == "a", start + 1 < tokens.count, let hundredIsOrdinal = hundredWord(tokens[start + 1]) {
            if hundredIsOrdinal { return Parsed(value: 100, consumed: 2, isOrdinal: true) }
            hundreds = 100
            i = start + 2
        } else if let hundredIsOrdinal = hundredWord(first) {
            if hundredIsOrdinal { return Parsed(value: 100, consumed: 1, isOrdinal: true) }
            hundreds = 100
            i = start + 1
        } else if let small = scanBelowHundred(tokens, from: start, allowHomophones: allowHomophones) {
            let next = start + small.consumed
            guard !small.isOrdinal, small.consumed == 1, (1...9).contains(small.value), next < tokens.count,
                  let hundredIsOrdinal = hundredWord(tokens[next]) else {
                return small
            }
            if hundredIsOrdinal { return Parsed(value: small.value * 100, consumed: 2, isOrdinal: true) }
            hundreds = small.value * 100
            i = next + 1
        } else {
            return nil
        }

        // After "hundred": optionally "and", then a number below a hundred.
        var j = i
        if j < tokens.count, tokens[j].lowercased() == "and" { j += 1 }
        if let rest = scanBelowHundred(tokens, from: j, allowHomophones: allowHomophones), rest.value > 0 {
            hundreds += rest.value
            return Parsed(value: hundreds, consumed: j + rest.consumed - start, isOrdinal: rest.isOrdinal)
        }
        return Parsed(value: hundreds, consumed: i - start, isOrdinal: false)
    }

    /// Lowercases, joins apostrophes ("let's" -> "lets"), splits on everything that is not a letter or
    /// digit and turns "%" into the word "percent". With `keepDecimalPoints`, "0.5" stays one token.
    /// Commas between digits are dropped ("1,000" -> "1000").
    static func tokenize(_ text: String, keepDecimalPoints: Bool = false) -> [String] {
        let scalars = Array(text.lowercased().unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)
        for (k, s) in scalars.enumerated() {
            if CharacterSet.alphanumerics.contains(s) {
                out.append(s)
            } else if apostrophes.contains(s) {
                continue
            } else if s == "%" {
                out.append(contentsOf: " percent ".unicodeScalars)
            } else if (s == "." && keepDecimalPoints) || s == ",",
                      k > 0, k + 1 < scalars.count,
                      isASCIIDigit(scalars[k - 1]), isASCIIDigit(scalars[k + 1]) {
                if s == "." { out.append(s) }
            } else {
                out.append(" ")
            }
        }
        return String(out).split(separator: " ").map(String.init)
    }

    // MARK: - Word tables

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let unitOrdinals: [String: Int] = [
        "zeroth": 0, "first": 1, "second": 2, "third": 3, "fourth": 4,
        "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
    ]
    private static let teenOrdinals: [String: Int] = [
        "tenth": 10, "eleventh": 11, "twelfth": 12, "twelth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
    ]
    private static let tensOrdinals: [String: Int] = [
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
        "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
    ]
    private static let homophones: [String: Int] = [
        "to": 2, "too": 2, "won": 1, "for": 4, "fore": 4, "ate": 8,
    ]
    private static let apostrophes: Set<Unicode.Scalar> = ["'", "\u{2019}", "\u{2018}", "\u{02BC}", "`"]

    // MARK: - Helpers

    private static func isASCIIDigit(_ s: Unicode.Scalar) -> Bool {
        s.value >= 48 && s.value <= 57
    }

    /// "12" -> 12, "3rd" -> 3 (ordinal). ASCII digits only.
    private static func digitValue(_ token: String) -> (value: Int, isOrdinal: Bool)? {
        var body = Substring(token)
        var ordinal = false
        for suffix in ["st", "nd", "rd", "th"] where body.hasSuffix(suffix) {
            body = body.dropLast(2)
            ordinal = true
            break
        }
        guard !body.isEmpty, body.unicodeScalars.allSatisfy(isASCIIDigit), let v = Int(body) else { return nil }
        return (v, ordinal)
    }

    /// "hundred" -> false, "hundredth" -> true (ordinal), anything else -> nil.
    private static func hundredWord(_ token: String) -> Bool? {
        switch token.lowercased() {
        case "hundred": return false
        case "hundredth": return true
        default: return nil
        }
    }

    /// 0...99 spoken with words (or a homophone), possibly as a two-token compound.
    private static func scanBelowHundred(_ tokens: [String], from i: Int, allowHomophones: Bool) -> Parsed? {
        guard i >= 0, i < tokens.count else { return nil }
        let t = tokens[i].lowercased()
        if let v = tens[t] {
            if i + 1 < tokens.count {
                let next = tokens[i + 1].lowercased()
                if let u = unitValue(next, allowHomophones: allowHomophones), u > 0 {
                    return Parsed(value: v + u, consumed: 2, isOrdinal: false)
                }
                if let u = unitOrdinals[next], u > 0 {
                    return Parsed(value: v + u, consumed: 2, isOrdinal: true)
                }
            }
            return Parsed(value: v, consumed: 1, isOrdinal: false)
        }
        if let v = tensOrdinals[t] { return Parsed(value: v, consumed: 1, isOrdinal: true) }
        if let v = teens[t] { return Parsed(value: v, consumed: 1, isOrdinal: false) }
        if let v = teenOrdinals[t] { return Parsed(value: v, consumed: 1, isOrdinal: true) }
        if let v = unitOrdinals[t] { return Parsed(value: v, consumed: 1, isOrdinal: true) }
        if let v = unitValue(t, allowHomophones: allowHomophones) { return Parsed(value: v, consumed: 1, isOrdinal: false) }
        return nil
    }

    private static func unitValue(_ t: String, allowHomophones: Bool) -> Int? {
        if let v = units[t] { return v }
        if allowHomophones, let v = homophones[t] { return v }
        return nil
    }
}
