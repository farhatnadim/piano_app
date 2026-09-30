import Foundation

/// Extracts YouTube video ids and start times from whatever a parent pastes: full links, short links,
/// embed/shorts/live links, links without a scheme, links buried in a sentence, or a bare 11-character id.
public enum YouTubeLink {

    /// The 11-character video id in `input`, or nil if none is found.
    ///
    /// Accepts `youtube.com/watch?v=ID` (also `www.`, `m.`, `music.` and other subdomains),
    /// `youtube.com/embed/ID`, `youtube-nocookie.com/embed/ID`, `/shorts/ID`, `/live/ID`, `/v/ID`,
    /// `youtu.be/ID`, with or without a scheme, extra query parameters or a fragment; the link may be
    /// surrounded by other text. A bare id is accepted only when it is the whole input.
    public static func videoID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let unquoted = trimmed.trimmingCharacters(in: wrapperCharacters)
        if isValidVideoID(unquoted) { return unquoted }
        for candidate in linkCandidates(in: trimmed) {
            if let id = videoID(in: candidate) { return id }
        }
        return nil
    }

    /// The start time in seconds from a `t=` or `start=` parameter (query or fragment) of the first
    /// YouTube link in `input`: `"90"`, `"90s"`, `"1m30s"`, `"1h2m3s"` (also `"1:30"`). Nil if absent.
    public static func startTime(from input: String) -> Double? {
        for candidate in linkCandidates(in: input.trimmingCharacters(in: .whitespacesAndNewlines)) {
            guard candidate.kind != nil else { continue }
            for key in ["t", "start", "time_continue"] {
                if let value = candidate.query.first(where: { $0.name == key })?.value,
                   let seconds = parseTime(value) {
                    return seconds
                }
            }
            for key in ["t", "start"] {
                if let value = candidate.fragment.first(where: { $0.name == key })?.value,
                   let seconds = parseTime(value) {
                    return seconds
                }
            }
            return nil
        }
        return nil
    }

    /// True for exactly 11 characters from `[A-Za-z0-9_-]`.
    public static func isValidVideoID(_ id: String) -> Bool {
        id.unicodeScalars.count == 11 && id.unicodeScalars.allSatisfy(isIDCharacter)
    }

    /// `https://www.youtube.com/watch?v=ID`
    public static func watchURL(videoID: String) -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "www.youtube.com"
        c.path = "/watch"
        c.queryItems = [URLQueryItem(name: "v", value: videoID)]
        return c.url ?? URL(string: "https://www.youtube.com/")!
    }

    /// `https://i.ytimg.com/vi/ID/hqdefault.jpg`
    public static func thumbnailURL(videoID: String) -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "i.ytimg.com"
        c.path = "/vi/\(videoID)/hqdefault.jpg"
        return c.url ?? URL(string: "https://i.ytimg.com/")!
    }

    // MARK: - Link parsing

    private enum HostKind {
        /// youtube.com, *.youtube.com, youtube-nocookie.com, *.youtube-nocookie.com
        case full
        /// youtu.be
        case short
    }

    private struct QueryItem {
        var name: String
        var value: String
    }

    /// A loosely parsed URL-like string.
    private struct Candidate {
        var kind: HostKind?
        var path: [String]
        var query: [QueryItem]
        var fragment: [QueryItem]
    }

    /// Path segments that look like ids but are not videos.
    private static let reservedIDs: Set<String> = ["videoseries", "live_stream"]

    private static let wrapperCharacters = CharacterSet(charactersIn: "<>\"'()[]{}\u{201C}\u{201D}\u{2018}\u{2019}")
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?")

    private static func isIDCharacter(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 48...57, 65...90, 97...122: return true   // 0-9 A-Z a-z
        case 45, 95: return true                       // - _
        default: return false
        }
    }

    /// The longest leading run of id characters, if it is exactly 11 long and not reserved.
    private static func idPrefix(_ s: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            guard isIDCharacter(u) else { break }
            scalars.append(u)
            if scalars.count > 11 { return nil }
        }
        let id = String(scalars)
        guard id.count == 11, !reservedIDs.contains(id) else { return nil }
        return id
    }

    /// Pieces of `text` that look like YouTube links.
    private static func linkCandidates(in text: String) -> [Candidate] {
        let separators = CharacterSet.whitespacesAndNewlines.union(wrapperCharacters).union(CharacterSet(charactersIn: "|,"))
        return text.components(separatedBy: separators).compactMap { piece -> Candidate? in
            var s = piece.trimmingCharacters(in: trailingPunctuation)
            guard s.lowercased().contains("youtu") else { return nil }
            // "Link:https://…" — start at the scheme when there is one.
            if let r = s.range(of: "http", options: .caseInsensitive), r.lowerBound != s.startIndex {
                s = String(s[r.lowerBound...])
            }
            let c = parse(s)
            return c.kind == nil ? nil : c
        }
    }

    private static func parse(_ string: String) -> Candidate {
        var rest = Substring(string)
        if let r = rest.range(of: "://") {
            rest = rest[r.upperBound...]
        } else if rest.hasPrefix("//") {
            rest = rest.dropFirst(2)
        }
        var fragment = Substring("")
        if let h = rest.firstIndex(of: "#") {
            fragment = rest[rest.index(after: h)...]
            rest = rest[..<h]
        }
        var query = Substring("")
        if let q = rest.firstIndex(of: "?") {
            query = rest[rest.index(after: q)...]
            rest = rest[..<q]
        }
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        var host = rest[..<slash].lowercased()
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if let colon = host.lastIndex(of: ":"),
           host[host.index(after: colon)...].unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) {
            host = String(host[..<colon])
        }
        if host.hasSuffix(".") { host.removeLast() }
        let path = rest[slash...].split(separator: "/").map(String.init)
        return Candidate(kind: hostKind(host), path: path, query: queryItems(query), fragment: queryItems(fragment))
    }

    private static func hostKind(_ host: String) -> HostKind? {
        for domain in ["youtube.com", "youtube-nocookie.com"] where host == domain || host.hasSuffix("." + domain) {
            return .full
        }
        if host == "youtu.be" || host.hasSuffix(".youtu.be") { return .short }
        return nil
    }

    private static func queryItems(_ query: Substring) -> [QueryItem] {
        query.split(whereSeparator: { $0 == "&" || $0 == ";" }).compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = parts.first, !rawName.isEmpty else { return nil }
            let rawValue = parts.count > 1 ? String(parts[1]) : ""
            let name = (String(rawName).removingPercentEncoding ?? String(rawName)).lowercased()
            let value = rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawValue
            return QueryItem(name: name, value: value)
        }
    }

    private static func videoID(in c: Candidate, depth: Int = 0) -> String? {
        switch c.kind {
        case .none:
            return nil
        case .short?:
            return c.path.first.flatMap(idPrefix)
        case .full?:
            if let first = c.path.first?.lowercased() {
                switch first {
                case "embed", "shorts", "live", "v", "e", "watch":
                    if c.path.count >= 2, let id = idPrefix(c.path[1]) { return id }
                case "attribution_link":
                    // youtube.com/attribution_link?u=/watch%3Fv%3DID%26feature%3Dshare
                    if depth == 0, let u = c.query.first(where: { $0.name == "u" })?.value {
                        let inner = parse("https://www.youtube.com" + (u.hasPrefix("/") ? u : "/" + u))
                        if let id = videoID(in: inner, depth: depth + 1) { return id }
                    }
                default:
                    break
                }
            }
            if let v = c.query.first(where: { $0.name == "v" })?.value { return idPrefix(v) }
            return nil
        }
    }

    /// "90", "90s", "1m30s", "1h2m3s", "2m", "1m30", "1:30", "1:02:03" -> seconds.
    static func parseTime(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        let isNumber: (Substring) -> Bool = { part in
            !part.isEmpty && part.filter { $0 == "." }.count <= 1 &&
                part.unicodeScalars.allSatisfy { ($0.value >= 48 && $0.value <= 57) || $0 == "." } &&
                part != "."
        }
        if s.contains(":") {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 3, parts.allSatisfy(isNumber) else { return nil }
            let total = parts.reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
            return total.isFinite ? total : nil
        }
        var total = 0.0
        var number = Substring("")
        var sawUnit = false
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch.isASCII && (ch.isNumber || ch == ".") {
                number.append(ch)
            } else {
                let multiplier: Double
                switch ch {
                case "h": multiplier = 3600
                case "m": multiplier = 60
                case "s": multiplier = 1
                default: return nil
                }
                guard isNumber(number), let v = Double(number) else { return nil }
                total += v * multiplier
                number = ""
                sawUnit = true
            }
            i = s.index(after: i)
        }
        if !number.isEmpty {
            guard isNumber(number), let v = Double(number) else { return nil }
            total += v
        } else if !sawUnit {
            return nil
        }
        return total.isFinite ? total : nil
    }
}
