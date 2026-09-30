import Foundation

/// Something that can be read pixel by pixel: one frame of video.
public protocol VideoFrame {
    var width: Int { get }
    var height: Int { get }
    /// Red, green and blue at a pixel, each 0...1.
    func rgb(x: Int, y: Int) -> (r: Float, g: Float, b: Float)
}

/// Reads the notes of a piano tutorial video (the kind where notes fall onto an on-screen keyboard and the
/// keys light up in colour as they are played) from its pictures instead of its sound.
///
/// First it finds the keyboard: a band of the picture where regular dark black keys alternate with bright
/// white ones, in the piano's groups of two and three. From the groups it works out which key is which (the
/// octave is a guess until `SongTranscriber` lines the notes up with the sound). From then on, each frame
/// only looks at one small patch per key: a key is down while its patch is strongly coloured (a resting key
/// is white or black; a played one is lit green, blue, orange…).
///
/// Feed frames in time order with `read(_:at:)`, then take `notes()`.
public final class KeyboardVideoReader {
    /// Where the keys are, in pixels of the frames being read.
    public struct Layout: Equatable, Sendable {
        public struct Key: Equatable, Sendable {
            public var midi: Int
            public var x: Double
            public var y: Double
            public var isBlack: Bool
        }
        public var keys: [Key]
        /// Width of a white key in pixels.
        public var whiteKeyWidth: Double
        public var frameWidth: Int
        public var frameHeight: Int
    }

    public struct Settings: Sendable {
        /// Only this part of the frame (0...1 fractions of width and height) is searched for a keyboard.
        public var searchRect: (x: Double, y: Double, width: Double, height: Double) = (0, 0, 1, 1)
        /// A key counts as lit when its colour's saturation is at least this (resting keys are grey).
        public var litSaturation: Float = 0.32
        /// ...and it isn't this dark.
        public var litMinimumValue: Float = 0.22
        /// Frames a key must stay lit (or unlit) before it counts as pressed (or released).
        public var debounceFrames = 2
        /// Consecutive frames the same keyboard must be found in before it is trusted.
        public var framesToLock = 4

        public init() {}
    }

    public private(set) var layout: Layout?
    public var settings: Settings

    private var candidate: Layout?
    private var candidateCount = 0
    private var framesSinceSearch = 0
    /// Per key: whether it is down, frames the raw reading has disagreed, when it went down, and its colour.
    private var states: [KeyState] = []
    private var finished: [VideoNote] = []
    private var lastTime: Double = 0

    private struct KeyState {
        var isDown = false
        var disagreeing = 0
        var since: Double = 0
        var firstSeen: Double = 0
        var hue: Float = 0
    }

    /// A note read off the video: the key, when it lit up and went dark (seconds, the frames' clock) and
    /// the hue it lit up in (0...1; tutorial videos colour each hand differently).
    public struct VideoNote: Equatable, Sendable {
        public var midi: Int
        public var start: Double
        public var end: Double
        public var hue: Float

        public init(midi: Int, start: Double, end: Double, hue: Float) {
            self.midi = midi
            self.start = start
            self.end = end
            self.hue = hue
        }
    }

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Reads one frame taken at `time` (seconds, any clock that increases).
    public func read<F: VideoFrame>(_ frame: F, at time: Double) {
        lastTime = time
        guard let layout else {
            // Searching is the costly part: at most a few times a second.
            framesSinceSearch += 1
            guard framesSinceSearch >= 3 || candidate == nil else { return }
            framesSinceSearch = 0
            search(frame)
            return
        }
        guard layout.frameWidth == frame.width, layout.frameHeight == frame.height else { return }
        for (i, key) in layout.keys.enumerated() {
            let lit = isLit(frame, x: key.x, y: key.y, radius: max(1, layout.whiteKeyWidth * (key.isBlack ? 0.12 : 0.2)))
            update(key: i, lit: lit.lit, hue: lit.hue, at: time)
        }
    }

    /// The notes read so far (keys still down end at the last frame), sorted by start.
    public func notes() -> [VideoNote] {
        var result = finished
        if let layout {
            for (i, state) in states.enumerated() where state.isDown {
                result.append(VideoNote(midi: layout.keys[i].midi, start: state.since, end: lastTime, hue: state.hue))
            }
        }
        return result.sorted { ($0.start, $0.midi) < ($1.start, $1.midi) }
    }

    // MARK: - Reading keys

    private func update(key i: Int, lit: Bool, hue: Float, at time: Double) {
        var state = states[i]
        if lit == state.isDown {
            state.disagreeing = 0
        } else {
            if state.disagreeing == 0 { state.firstSeen = time }
            state.disagreeing += 1
            if lit { state.hue = hue }
            if state.disagreeing >= settings.debounceFrames {
                if lit {
                    state.isDown = true
                    state.since = state.firstSeen
                } else if let layout {
                    state.isDown = false
                    finished.append(VideoNote(midi: layout.keys[i].midi, start: state.since, end: state.firstSeen,
                                              hue: state.hue))
                }
                state.disagreeing = 0
            }
        }
        states[i] = state
    }

    private func isLit<F: VideoFrame>(_ frame: F, x: Double, y: Double, radius: Double) -> (lit: Bool, hue: Float) {
        var r: Float = 0, g: Float = 0, b: Float = 0, n: Float = 0
        let r0 = Int(radius.rounded())
        for dy in stride(from: -r0, through: r0, by: max(1, r0)) {
            for dx in stride(from: -r0, through: r0, by: max(1, r0)) {
                let px = Int(x.rounded()) + dx, py = Int(y.rounded()) + dy
                guard px >= 0, py >= 0, px < frame.width, py < frame.height else { continue }
                let c = frame.rgb(x: px, y: py)
                r += c.r; g += c.g; b += c.b; n += 1
            }
        }
        guard n > 0 else { return (false, 0) }
        let (h, s, v) = Self.hsv(r / n, g / n, b / n)
        return (s >= settings.litSaturation && v >= settings.litMinimumValue, h)
    }

    static func hsv(_ r: Float, _ g: Float, _ b: Float) -> (h: Float, s: Float, v: Float) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        let s = maxC > 0 ? delta / maxC : 0
        var h: Float = 0
        if delta > 0 {
            if maxC == r { h = (g - b) / delta } else if maxC == g { h = 2 + (b - r) / delta } else { h = 4 + (r - g) / delta }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, s, maxC)
    }

    // MARK: - Finding the keyboard

    private func search<F: VideoFrame>(_ frame: F) {
        guard let found = Self.findKeyboard(in: frame, settings: settings) else {
            candidate = nil
            candidateCount = 0
            return
        }
        if let previous = candidate, Self.sameKeyboard(previous, found) {
            candidateCount += 1
        } else {
            candidate = found
            candidateCount = 1
        }
        if candidateCount >= settings.framesToLock {
            layout = found
            states = Array(repeating: KeyState(), count: found.keys.count)
        }
    }

    static func sameKeyboard(_ a: Layout, _ b: Layout) -> Bool {
        guard a.keys.count == b.keys.count, a.frameWidth == b.frameWidth else { return false }
        return zip(a.keys, b.keys).allSatisfy { $0.midi == $1.midi && abs($0.x - $1.x) < a.whiteKeyWidth * 0.3 }
    }

    /// Finds a piano keyboard in `frame`, if there is one.
    public static func findKeyboard<F: VideoFrame>(in frame: F, settings: Settings = Settings()) -> Layout? {
        let x0 = max(0, Int(settings.searchRect.x * Double(frame.width)))
        let x1 = min(frame.width, Int((settings.searchRect.x + settings.searchRect.width) * Double(frame.width)))
        let y0 = max(0, Int(settings.searchRect.y * Double(frame.height)))
        let y1 = min(frame.height, Int((settings.searchRect.y + settings.searchRect.height) * Double(frame.height)))
        guard x1 - x0 >= 60, y1 - y0 >= 20 else { return nil }
        // Look at every row (up to ~400 of them) for a regular pattern of black keys.
        let rowStep = max(1, (y1 - y0) / 400)
        var best: (y: Int, keys: [Double], score: Int)?
        var rowsWithBest: [Int] = []
        for y in stride(from: y0, to: y1, by: rowStep) {
            guard let keys = blackKeyCenters(in: frame, row: y, from: x0, to: x1) else { continue }
            if best == nil || keys.count > best!.score {
                best = (y, keys, keys.count)
                rowsWithBest = [y]
            } else if keys.count == best!.score {
                rowsWithBest.append(y)
            }
        }
        guard let found = best, found.score >= 5 else { return nil }
        // The black keys' band: the rows that show the same pattern. Sample black keys low in the band (clear of
        // falling notes above the keyboard), white keys a little below the band.
        let bandTop = rowsWithBest.min() ?? found.y
        let bandBottom = rowsWithBest.max() ?? found.y
        let row = bandTop + (bandBottom - bandTop) * 3 / 4
        guard let blacks = blackKeyCenters(in: frame, row: row, from: x0, to: x1) ?? Optional(found.keys),
              let named = nameBlackKeys(blacks) else { return nil }
        let bandHeight = max(4, bandBottom - bandTop + 1)
        var whiteY = Double(bandBottom) + Double(bandHeight) * 0.35
        whiteY = min(Double(frame.height - 1), whiteY)
        let whiteWidth = named.whiteWidth
        var keys: [Layout.Key] = named.keys.map {
            Layout.Key(midi: $0.midi, x: $0.x, y: Double(row), isBlack: true)
        }
        keys += whiteKeys(between: named.keys, whiteWidth: whiteWidth, y: whiteY, frame: frame, from: x0, to: x1)
        keys.sort { $0.midi < $1.midi }
        return Layout(keys: keys, whiteKeyWidth: whiteWidth, frameWidth: frame.width, frameHeight: frame.height)
    }

    @inline(__always)
    private static func luminance<F: VideoFrame>(_ frame: F, _ x: Int, _ y: Int) -> Float {
        let c = frame.rgb(x: x, y: y)
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
    }

    /// Centres of the dark runs in a row that look like black keys: similar widths, bright in between, spaced
    /// like a piano's black keys. Nil when the row doesn't look like a keyboard.
    static func blackKeyCenters<F: VideoFrame>(in frame: F, row y: Int, from x0: Int, to x1: Int) -> [Double]? {
        var runs: [(start: Int, end: Int)] = []
        var runStart: Int?
        var brightPixels = 0
        for x in x0..<x1 {
            let l = luminance(frame, x, y)
            if l < 0.3 {
                // A dark stretch from the edge isn't a key: keys have bright keys on both sides.
                if runStart == nil { runStart = brightPixels > 0 ? x : -1 }
            } else {
                if let s = runStart, s >= 0 { runs.append((s, x)) }
                runStart = nil
                if l > 0.6 { brightPixels += 1 }
            }
        }
        let span = Double(x1 - x0)
        // Black keys: between 0.4 % and 3 % of the searched width each.
        runs = runs.filter { Double($0.end - $0.start) >= span * 0.004 && Double($0.end - $0.start) <= span * 0.03 }
        guard runs.count >= 5, Double(brightPixels) > Double(runs.count) * 0.004 * span else { return nil }
        let widths = runs.map { Double($0.end - $0.start) }.sorted()
        let medianWidth = widths[widths.count / 2]
        runs = runs.filter { abs(Double($0.end - $0.start) - medianWidth) <= medianWidth * 0.35 }
        guard runs.count >= 5 else { return nil }
        let centers = runs.map { Double($0.start + $0.end) / 2 }
        // Gaps come in two sizes: about one white key (within a group) and about two (between groups).
        let gaps = zip(centers.dropFirst(), centers).map { $0 - $1 }
        let small = gaps.sorted()[gaps.count / 4]
        guard small > medianWidth * 1.2 else { return nil }
        for gap in gaps {
            let ratio = gap / small
            // Drawn keyboards space black keys differently: between groups 1.35 to 2.5 times the gap within.
            guard (0.75...1.3).contains(ratio) || (1.35...2.6).contains(ratio) else { return nil }
        }
        return centers
    }

    /// Names black keys from their grouping (twos: C♯ D♯, threes: F♯ G♯ A♯). The octave is placed so the
    /// middle of the keyboard falls near middle C — or exactly, when the whole 88-key piano is in view.
    static func nameBlackKeys(_ centers: [Double]) -> (keys: [(midi: Int, x: Double)], whiteWidth: Double)? {
        guard centers.count >= 5 else { return nil }
        let gaps = zip(centers.dropFirst(), centers).map { $0 - $1 }
        let small = gaps.sorted()[gaps.count / 4]
        var groups: [[Double]] = [[centers[0]]]
        for (i, gap) in gaps.enumerated() {
            if gap / small > 1.32 { groups.append([centers[i + 1]]) } else { groups[groups.count - 1].append(centers[i + 1]) }
        }
        guard groups.allSatisfy({ $0.count <= 3 }) else { return nil }
        // Groups alternate two/three. Find the parity from any complete group.
        guard let anchor = groups.indices.first(where: { $0 > 0 && $0 < groups.count - 1 }) ?? groups.indices.first(where: { groups[$0].count == 3 })
        else { return nil }
        let anchorIsThree = groups[anchor].count == 3
        var result: [(midi: Int, x: Double)] = []
        // Pitch classes: twos = C♯ D♯ (1, 3); threes = F♯ G♯ A♯ (6, 8, 10). Octave counter goes up at each two.
        var octave = 0
        for (i, group) in groups.enumerated() {
            let isThree = ((i - anchor) % 2 == 0) == anchorIsThree
            if !isThree && i > 0 { octave += 1 }
            let classes = isThree ? [6, 8, 10] : [1, 3]
            guard group.count <= classes.count else { return nil }
            // A cut-off group at the start keeps its last keys; elsewhere its first.
            let used = i == 0 ? Array(classes.suffix(group.count)) : Array(classes.prefix(group.count))
            for (x, pc) in zip(group, used) { result.append((octave * 12 + pc, x)) }
        }
        // Check the pattern held: complete inner groups must be full.
        for i in groups.indices where i > 0 && i < groups.count - 1 {
            let isThree = ((i - anchor) % 2 == 0) == anchorIsThree
            if groups[i].count != (isThree ? 3 : 2) { return nil }
        }
        // A white key: an octave (five black keys on) is seven of them.
        var octaveSpans = (0..<max(0, centers.count - 5)).map { (centers[$0 + 5] - centers[$0]) / 7 }.sorted()
        if octaveSpans.isEmpty { octaveSpans = [small] }
        let whiteWidth = octaveSpans[octaveSpans.count / 2]
        // Place the octave: the full piano has 36 black keys, A♯0 first; otherwise centre near middle C.
        let shift: Int
        if result.count == 36, result.first.map({ $0.midi % 12 == 10 }) == true {
            shift = 22 - result[0].midi
        } else {
            let middle = result[result.count / 2].midi
            let targetClass = middle % 12
            // The black key nearest the middle goes into the octave of middle C (60...71).
            shift = (60 + targetClass) - middle
        }
        return (result.map { ($0.midi + shift, $0.x) }, whiteWidth)
    }

    /// The white keys around the black ones: each black key sits on the line between two white keys, and
    /// E|F and B|C have no black key, one white key further on. The keyboard's ends are found by following
    /// bright keys outwards.
    static func whiteKeys<F: VideoFrame>(between blacks: [(midi: Int, x: Double)], whiteWidth w: Double, y: Double,
                                         frame: F, from x0: Int, to x1: Int) -> [Layout.Key] {
        var boundaries: [(x: Double, left: Int, right: Int)] = []
        for black in blacks {
            boundaries.append((black.x, black.midi - 1, black.midi + 1))
            let pc = black.midi % 12
            if pc == 3 { boundaries.append((black.x + w, black.midi + 1, black.midi + 2)) }     // E|F after D♯
            if pc == 10 { boundaries.append((black.x + w, black.midi + 1, black.midi + 2)) }    // B|C after A♯
            if pc == 1 { boundaries.append((black.x - w, black.midi - 2, black.midi - 1)) }     // B|C before C♯
            if pc == 6 { boundaries.append((black.x - w, black.midi - 2, black.midi - 1)) }     // E|F before F♯
        }
        var byLeft: [Int: Double] = [:]
        var byRight: [Int: Double] = [:]
        for b in boundaries {
            byLeft[b.left] = b.x
            byRight[b.right] = b.x
        }
        let yInt = Int(y.rounded())
        func isBrightKey(at x: Double) -> Bool {
            let xi = Int(x.rounded())
            guard xi >= x0, xi < x1, yInt >= 0, yInt < frame.height else { return false }
            return luminance(frame, xi, yInt) > 0.55 || KeyboardVideoReader.hsv(frame.rgb(x: xi, y: yInt).r, frame.rgb(x: xi, y: yInt).g,
                                                                               frame.rgb(x: xi, y: yInt).b).s > 0.3
        }
        var keys: [Layout.Key] = []
        let lowest = (byRight.keys.min() ?? 60), highest = (byLeft.keys.max() ?? 60)
        for midi in lowest...highest where !isBlack(midi) {
            let left = byRight[midi], right = byLeft[midi]
            let center: Double
            switch (left, right) {
            case let (l?, r?): center = (l + r) / 2
            case let (l?, nil): center = l + w / 2
            case let (nil, r?): center = r - w / 2
            default: continue
            }
            keys.append(.init(midi: midi, x: center, y: y, isBlack: false))
        }
        // Extend past the outermost boundaries while the picture still shows white keys.
        var low = (keys.first?.midi ?? lowest), lowX = keys.first?.x ?? 0
        while low > 21 {
            let next = low - 1
            if isBlack(next) { low = next; continue }
            let x = lowX - w
            guard isBrightKey(at: x) else { break }
            keys.insert(.init(midi: next, x: x, y: y, isBlack: false), at: 0)
            low = next; lowX = x
        }
        var high = (keys.last?.midi ?? highest), highX = keys.last?.x ?? 0
        while high < 108 {
            let next = high + 1
            if isBlack(next) { high = next; continue }
            let x = highX + w
            guard isBrightKey(at: x) else { break }
            keys.append(.init(midi: next, x: x, y: y, isBlack: false))
            high = next; highX = x
        }
        return keys
    }

    static func isBlack(_ midi: Int) -> Bool { [1, 3, 6, 8, 10].contains(((midi % 12) + 12) % 12) }
}
