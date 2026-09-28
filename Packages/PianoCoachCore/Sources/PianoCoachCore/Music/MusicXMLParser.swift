import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Errors thrown by `MusicXMLParser`.
public enum MusicXMLError: Error, Equatable {
    /// The data is not well-formed XML (message from the XML parser).
    case invalidXML(String)
    /// Well-formed XML that is not a supported MusicXML document (e.g. `score-timewise`).
    case unsupportedFormat(String)
    /// The score contains no pitched note attacks.
    case noNotes
}

/// Reads uncompressed MusicXML (`score-partwise`) into a `Score`.
///
/// What is interpreted:
/// * all parts are merged; measures are matched by their ordinal position in each part;
/// * `<divisions>` (per part, may change anywhere), `<backup>`, `<forward>`, `<chord/>`, rests,
///   unpitched notes, cue notes (they advance time but are not attacks) and grace notes (ignored);
/// * tied continuations (`<tie type="stop"/>`, or `<tied type="stop"/>` when no `<tie>` is present)
///   advance time but are not new attacks;
/// * time signatures (including additive "3+2" and composite signatures), tempo from the first
///   `<sound tempo>` or else the first `<metronome>`, title and composer;
/// * repeat barlines (`forward`/`backward`, `times`) and volta endings, unrolled into performance order.
///
/// Limitations: D.C./D.S./segno/coda/fine/to-coda jumps are ignored (the music is read straight through
/// after repeats are unrolled), nested repeats are not supported, `score-timewise` is rejected.
public enum MusicXMLParser {
    /// Parses MusicXML bytes (UTF-8, or UTF-16 with a BOM; DOCTYPE declarations are tolerated).
    /// - Parameter unrollRepeats: when false, measures stay in file order and repeats are ignored.
    public static func parse(data: Data, unrollRepeats: Bool = true) throws -> Score {
        let root: LiteXMLElement
        do {
            root = try LiteXML.parse(XMLTextEncoding.parserReadyData(data))
        } catch let error as LiteXML.ParseError {
            throw MusicXMLError.invalidXML(error.message)
        }
        return try interpret(root: root, unrollRepeats: unrollRepeats)
    }

    /// Parses a MusicXML document held in a string.
    public static func parse(string: String, unrollRepeats: Bool = true) throws -> Score {
        try parse(data: XMLTextEncoding.utf8Data(fromXMLString: string), unrollRepeats: unrollRepeats)
    }

    // MARK: - Interpretation

    /// A pitched attack inside one source measure.
    struct NoteRecord {
        /// Onset relative to the measure start, in quarter notes.
        var onset: Double
        var duration: Double
        var midi: Int
    }

    /// Everything gathered about one `<measure>` ordinal across all parts.
    struct SourceMeasure {
        var number: String
        var notes: [NoteRecord] = []
        /// Furthest time position reached by any part, in quarter notes.
        var contentLength: Double = 0
        var declaredTime: TimeSignature?
        var repeats = RepeatInfo()
    }

    /// Repeat/volta markings of one source measure.
    struct RepeatInfo: Equatable {
        var hasForward = false
        var hasBackward = false
        /// Total number of plays requested by a backward repeat's `times` attribute.
        var times: Int?
        /// Pass numbers of an `<ending type="start">` on this measure.
        var endingStart: [Int]?
        /// An `<ending type="stop|discontinue">` is on this measure.
        var endingStop = false
    }

    static func interpret(root: LiteXMLElement, unrollRepeats: Bool) throws -> Score {
        switch root.name {
        case "score-partwise":
            break
        case "score-timewise":
            throw MusicXMLError.unsupportedFormat("score-timewise MusicXML is not supported")
        default:
            throw MusicXMLError.unsupportedFormat("root element <\(root.name)> is not a MusicXML score")
        }

        var source: [SourceMeasure] = []
        for part in root.children(named: "part") {
            var reader = PartReader()
            for (ordinal, measureNode) in part.children(named: "measure").enumerated() {
                if ordinal == source.count {
                    let label = measureNode.attribute("number")?.trimmingCharacters(in: .whitespaces) ?? ""
                    source.append(SourceMeasure(number: label.isEmpty ? String(ordinal + 1) : label))
                }
                reader.read(measureNode, into: &source[ordinal])
            }
        }
        guard !source.isEmpty else { throw MusicXMLError.noNotes }

        // Time signatures carry over in file order; empty measures take the signature's length.
        var signatures: [TimeSignature] = []
        var lengths: [Double] = []
        var current = TimeSignature.common
        for m in source {
            if let declared = m.declaredTime { current = declared }
            signatures.append(current)
            lengths.append(m.contentLength > 1e-9 ? m.contentLength : current.quarterBeatsPerMeasure)
        }

        let order = unrollRepeats ? performanceOrder(source.map(\.repeats)) : Array(source.indices)

        var measures: [ScoreMeasure] = []
        measures.reserveCapacity(order.count)
        var attacks: [(beat: Double, measure: Int, note: NoteRecord)] = []
        var start = 0.0
        for (index, s) in order.enumerated() {
            measures.append(ScoreMeasure(index: index, sourceIndex: s, number: source[s].number, startBeat: start,
                                         lengthBeats: lengths[s], timeSignature: signatures[s]))
            for note in source[s].notes {
                attacks.append((start + note.onset, index, note))
            }
            start += lengths[s]
        }

        let events = groupAttacks(attacks, measures: measures)
        guard !events.isEmpty else { throw MusicXMLError.noNotes }

        return Score(title: title(root), composer: composer(root), measures: measures, events: events,
                     initialTempoBPM: tempo(root))
    }

    /// Merges attacks at the same beat (within 1e-6) into events.
    static func groupAttacks(_ attacks: [(beat: Double, measure: Int, note: NoteRecord)],
                             measures: [ScoreMeasure]) -> [ScoreEvent] {
        let sorted = attacks.enumerated().sorted {
            $0.element.beat != $1.element.beat ? $0.element.beat < $1.element.beat : $0.offset < $1.offset
        }.map(\.element)
        var events: [ScoreEvent] = []
        var lastDuration = 0.0
        var i = 0
        while i < sorted.count {
            let first = sorted[i]
            var pitches = Set<Int>()
            var longest = 0.0
            var j = i
            while j < sorted.count, sorted[j].beat - first.beat <= 1e-6 {
                pitches.insert(sorted[j].note.midi)
                longest = max(longest, sorted[j].note.duration)
                j += 1
            }
            let measure = measures[first.measure]
            events.append(ScoreEvent(index: events.count, beat: first.beat, measureIndex: first.measure,
                                     sourceMeasureIndex: measure.sourceIndex,
                                     beatInMeasure: first.beat - measure.startBeat,
                                     pitches: pitches.sorted(), durationBeats: 0))
            lastDuration = longest
            i = j
        }
        for k in events.indices {
            events[k].durationBeats = k + 1 < events.count ? events[k + 1].beat - events[k].beat : lastDuration
        }
        return events
    }

    /// Unrolls repeat barlines and volta endings into a list of source-measure ordinals.
    ///
    /// A backward repeat jumps to the most recent forward repeat, or — without one — to the start of the
    /// piece or the measure after the previous completed repeat section. Measures inside an ending are
    /// played only on the passes it lists. A backward repeat with no `times` attribute plays its section
    /// twice, or (inside an ending such as "1, 2") once more than the highest pass the ending lists.
    static func performanceOrder(_ repeats: [RepeatInfo]) -> [Int] {
        // Which passes each measure belongs to (nil = every pass).
        var ending: [[Int]?] = []
        var endingEnds: [Bool] = []
        var open: [Int]?
        for r in repeats {
            if let start = r.endingStart {
                open = start
            } else if r.hasForward {
                open = nil  // a forward repeat always starts a fresh section
            }
            ending.append(open)
            let closes = open != nil && (r.endingStop || r.hasBackward)
            endingEnds.append(closes)
            if closes { open = nil }
        }

        var order: [Int] = []
        let cap = max(10_000, repeats.count * 64)
        var i = 0
        var sectionStart = 0
        var pass = 1
        while i < repeats.count, order.count < cap {
            let r = repeats[i]
            if let passes = ending[i], !passes.contains(pass) {
                i += 1
                continue
            }
            if r.hasForward, i != sectionStart {
                sectionStart = i
                pass = 1
            }
            order.append(i)
            if r.hasBackward {
                let plays = min(r.times ?? max(2, (ending[i]?.max() ?? 1) + 1), 64)
                if pass < plays {
                    pass += 1
                    i = sectionStart
                    continue
                }
                sectionStart = i + 1
                pass = 1
            } else if endingEnds[i] {
                // Left the last ending of a section: the next backward repeat starts after it.
                sectionStart = i + 1
                pass = 1
            }
            i += 1
        }
        return order
    }

    // MARK: - Per-part reading

    struct PartReader {
        var divisions: Double = 1

        mutating func read(_ measure: LiteXMLElement, into m: inout SourceMeasure) {
            // Position = base + offset / divisions (rebased whenever <divisions> changes mid-measure),
            // so positions are exact multiples of 1/divisions.
            var base = 0.0
            var offset = 0.0
            var lastOnset = 0.0
            var furthest = 0.0
            func position() -> Double { base + offset / divisions }

            for child in measure.children {
                switch child.name {
                case "attributes":
                    if let d = child.child("divisions").flatMap({ Double($0.trimmedText) }), d > 0 {
                        base = position()
                        offset = 0
                        divisions = d
                    }
                    if m.declaredTime == nil, let time = child.child("time"), let ts = MusicXMLParser.timeSignature(time) {
                        m.declaredTime = ts
                    }
                case "note":
                    if child.child("grace") != nil { continue }
                    let duration = max(0, MusicXMLParser.duration(child))
                    let onset: Double
                    if child.child("chord") != nil {
                        onset = lastOnset
                    } else {
                        onset = position()
                        lastOnset = onset
                        offset += duration
                        furthest = max(furthest, position())
                    }
                    guard child.child("cue") == nil, child.child("rest") == nil,
                          let pitch = child.child("pitch"), let midi = MusicXMLParser.midiNumber(pitch),
                          !MusicXMLParser.isTiedContinuation(child) else { continue }
                    m.notes.append(NoteRecord(onset: onset, duration: duration / divisions, midi: midi))
                case "backup":
                    offset -= max(0, MusicXMLParser.duration(child))
                    if position() < 0 { offset = -base * divisions }
                case "forward":
                    offset += max(0, MusicXMLParser.duration(child))
                    furthest = max(furthest, position())
                case "barline":
                    MusicXMLParser.readBarline(child, into: &m.repeats)
                default:
                    break
                }
            }
            m.contentLength = max(m.contentLength, furthest)
        }
    }

    static func readBarline(_ barline: LiteXMLElement, into r: inout RepeatInfo) {
        if let rep = barline.child("repeat") {
            switch rep.attribute("direction") {
            case "forward":
                r.hasForward = true
            case "backward":
                r.hasBackward = true
                if r.times == nil, let t = rep.attribute("times").flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), t > 0 {
                    r.times = t
                }
            default:
                break
            }
        }
        for e in barline.children(named: "ending") {
            switch e.attribute("type") {
            case "start":
                if r.endingStart == nil, let numbers = endingNumbers(e.attribute("number") ?? "") {
                    r.endingStart = numbers
                }
            case "stop", "discontinue":
                r.endingStop = true
            default:
                break
            }
        }
    }

    /// Parses an ending number list: "1", "1, 2", "1 2", "1.", "1-3". Nil if nothing usable.
    static func endingNumbers(_ text: String) -> [Int]? {
        var result: [Int] = []
        let separators = CharacterSet(charactersIn: ", ;")
        for token in text.components(separatedBy: separators) {
            let t = token.trimmingCharacters(in: CharacterSet(charactersIn: ". \t\n"))
            if t.isEmpty { continue }
            let bounds = t.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if bounds.count == 2, let lo = bounds[0], let hi = bounds[1], lo >= 1, hi >= lo, hi - lo < 64 {
                result.append(contentsOf: lo...hi)
            } else if bounds.count == 1, let n = bounds[0], n >= 1 {
                result.append(n)
            }
        }
        return result.isEmpty ? nil : result
    }

    static func duration(_ node: LiteXMLElement) -> Double {
        node.child("duration").flatMap { Double($0.trimmedText) } ?? 0
    }

    static func midiNumber(_ pitch: LiteXMLElement) -> Int? {
        guard let step = pitch.child("step")?.trimmedText,
              let octave = pitch.child("octave").flatMap({ Int($0.trimmedText) }) else { return nil }
        let alter = pitch.child("alter").flatMap { Double($0.trimmedText) } ?? 0
        guard let midi = Pitch.midiNumber(step: step, alter: Int(alter.rounded()), octave: octave),
              (0...127).contains(midi) else { return nil }
        return midi
    }

    static func isTiedContinuation(_ note: LiteXMLElement) -> Bool {
        let ties = note.children(named: "tie")
        if !ties.isEmpty { return ties.contains { $0.attribute("type") == "stop" } }
        return note.children(named: "notations").contains { notations in
            notations.children(named: "tied").contains { $0.attribute("type") == "stop" }
        }
    }

    /// `<time>` -> signature. Additive beats ("3+2") are summed; composite signatures
    /// (several beats/beat-type pairs) are expressed over their least common beat type.
    static func timeSignature(_ time: LiteXMLElement) -> TimeSignature? {
        let beats = time.children(named: "beats").map { node -> Int in
            node.trimmedText.split(separator: "+").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.reduce(0, +)
        }
        let types = time.children(named: "beat-type").map { node -> Int in
            Int(node.trimmedText.split(separator: "+").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "") ?? 0
        }
        let pairs = zip(beats, types).filter { $0.0 > 0 && $0.1 > 0 }
        guard let first = pairs.first else { return nil }
        if pairs.count == 1 { return TimeSignature(beats: first.0, beatType: first.1) }
        let common = pairs.map(\.1).reduce(1) { lcm($0, $1) }
        return TimeSignature(beats: pairs.reduce(0) { $0 + $1.0 * (common / $1.1) }, beatType: common)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
    private static func lcm(_ a: Int, _ b: Int) -> Int { a / gcd(a, b) * b }

    // MARK: - Header data

    static func title(_ root: LiteXMLElement) -> String? {
        root.child("work")?.child("work-title")?.trimmedText.nonEmpty ?? root.child("movement-title")?.trimmedText.nonEmpty
    }

    static func composer(_ root: LiteXMLElement) -> String? {
        root.child("identification")?.children(named: "creator")
            .first { $0.attribute("type")?.lowercased() == "composer" }?.trimmedText.nonEmpty
    }

    /// Quarter-note BPM from the first `<sound tempo>`, else the first usable `<metronome>`.
    static func tempo(_ root: LiteXMLElement) -> Double? {
        if let sound = root.firstDescendant(where: { $0.name == "sound" && soundTempo($0) != nil }) {
            return soundTempo(sound)
        }
        if let metronome = root.firstDescendant(where: { $0.name == "metronome" && metronomeTempo($0) != nil }) {
            return metronomeTempo(metronome)
        }
        return nil
    }

    private static func soundTempo(_ sound: LiteXMLElement) -> Double? {
        guard let text = sound.attribute("tempo"), let value = Double(text.trimmingCharacters(in: .whitespaces)),
              value > 0, value.isFinite else { return nil }
        return value
    }

    static let beatUnitQuarters: [String: Double] = [
        "maxima": 32, "long": 16, "breve": 8, "whole": 4, "half": 2, "quarter": 1, "eighth": 0.5,
        "16th": 0.25, "32nd": 0.125, "64th": 0.0625, "128th": 0.03125, "256th": 0.015625,
    ]

    /// `<metronome><beat-unit>…</beat-unit>[<beat-unit-dot/>…]<per-minute>…</per-minute></metronome>`
    /// converted to quarter notes per minute. Metric modulations (two beat units) are skipped.
    private static func metronomeTempo(_ metronome: LiteXMLElement) -> Double? {
        let units = metronome.children(named: "beat-unit")
        guard units.count == 1, let unit = beatUnitQuarters[units[0].trimmedText.lowercased()],
              let perMinuteText = metronome.child("per-minute")?.trimmedText,
              let perMinute = leadingNumber(in: perMinuteText), perMinute > 0 else { return nil }
        let dots = metronome.children(named: "beat-unit-dot").count
        return perMinute * unit * (2 - pow(0.5, Double(dots)))
    }

    /// First decimal number in a string ("c. 72" -> 72, "60-66" -> 60).
    static func leadingNumber(in text: String) -> Double? {
        var digits = ""
        var seenDot = false
        for ch in text {
            if ch.isASCII, ch.isNumber {
                digits.append(ch)
            } else if ch == ".", !seenDot, !digits.isEmpty {
                seenDot = true
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            }
        }
        if digits.hasSuffix(".") { digits.removeLast() }
        return Double(digits)
    }
}

// MARK: - Light DOM

/// A minimal element tree built from `XMLParser` (SAX) events.
final class LiteXMLElement {
    let name: String
    let attributes: [String: String]
    fileprivate(set) var children: [LiteXMLElement] = []
    /// Character data of a leaf element (cleared for elements with child elements).
    fileprivate(set) var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(_ name: String) -> LiteXMLElement? { children.first { $0.name == name } }
    func children(named name: String) -> [LiteXMLElement] { children.filter { $0.name == name } }
    func attribute(_ name: String) -> String? { attributes[name] }
    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Depth-first, document-order search (including `self`).
    func firstDescendant(where predicate: (LiteXMLElement) -> Bool) -> LiteXMLElement? {
        if predicate(self) { return self }
        for c in children {
            if let found = c.firstDescendant(where: predicate) { return found }
        }
        return nil
    }
}

enum LiteXML {
    struct ParseError: Error {
        var message: String
    }

    /// Parses XML into a tree. External entities/DTDs are never resolved.
    static func parse(_ data: Data) throws -> LiteXMLElement {
        let builder = LiteXMLBuilder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = builder
        let ok = parser.parse()
        if !ok || builder.failure != nil {
            let message = builder.failure ?? parser.parserError.map { "\($0)" } ?? "unknown XML error"
            throw ParseError(message: message)
        }
        guard let root = builder.root else { throw ParseError(message: "no root element") }
        return root
    }
}

private final class LiteXMLBuilder: NSObject, XMLParserDelegate {
    var root: LiteXMLElement?
    var stack: [LiteXMLElement] = []
    var failure: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        // Drop any namespace prefix ("mx:note" -> "note").
        let name = elementName.firstIndex(of: ":").map { String(elementName[elementName.index(after: $0)...]) } ?? elementName
        let node = LiteXMLElement(name: name, attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(node)
        } else if root == nil {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let node = stack.popLast() else { return }
        if !node.children.isEmpty { node.text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if failure == nil {
            failure = "line \(parser.lineNumber), column \(parser.columnNumber): \(parseError.localizedDescription)"
        }
    }
}

// MARK: - Text encodings

enum XMLTextEncoding {
    /// Decodes XML bytes to a string: UTF-8 (with or without BOM), UTF-16 with a BOM (or detectable
    /// without one), or the Latin-1 family when the XML declaration says so. Nil if undecodable.
    static func decode(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if head.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if head.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        if head == [0x3C, 0x00, 0x3F, 0x00] { return String(data: data, encoding: .utf16LittleEndian) }
        if head == [0x00, 0x3C, 0x00, 0x3F] { return String(data: data, encoding: .utf16BigEndian) }
        if let s = String(data: data, encoding: .utf8) { return s }
        let declaration = String(decoding: data.prefix(200), as: UTF8.self).lowercased()
        if declaration.contains("iso-8859-1") || declaration.contains("latin1") || declaration.contains("latin-1") {
            return String(data: data, encoding: .isoLatin1)
        }
        if declaration.contains("windows-1252") || declaration.contains("cp1252") {
            return String(data: data, encoding: .windowsCP1252)
        }
        return nil
    }

    /// Returns bytes the XML parser can read reliably: UTF-16 input is transcoded to UTF-8
    /// (with its declaration rewritten); anything else is passed through unchanged.
    static func parserReadyData(_ data: Data) -> Data {
        let head = [UInt8](data.prefix(4))
        let isUTF16 = head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF])
            || head == [0x3C, 0x00, 0x3F, 0x00] || head == [0x00, 0x3C, 0x00, 0x3F]
        guard isUTF16, let text = decode(data) else { return data }
        return utf8Data(fromXMLString: text)
    }

    /// UTF-8 bytes for an XML string, with any leading BOM removed and the declared encoding set to UTF-8.
    static func utf8Data(fromXMLString string: String) -> Data {
        var text = string
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if text.hasPrefix("<?xml"), let end = text.range(of: "?>"),
           let encoding = text.range(of: "encoding\\s*=\\s*[\"'][^\"']*[\"']", options: .regularExpression,
                                     range: text.startIndex..<end.lowerBound) {
            text.replaceSubrange(encoding, with: "encoding=\"UTF-8\"")
        }
        return Data(text.utf8)
    }
}

fileprivate extension String {
    /// Nil for an empty string.
    var nonEmpty: String? { isEmpty ? nil : self }
}
