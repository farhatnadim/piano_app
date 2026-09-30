import Foundation
import PianoCoachCore

/// How much of the keyboard the game shows: the child's choice, kept in `@AppStorage(KeyboardZoom.storageKey)`.
/// By default the keys from the song's lowest note to its highest, held still: a keyboard that zooms and
/// slides is distracting mid-song.
enum KeyboardZoom: String, CaseIterable, Identifiable {
    /// The keys between the song's lowest and highest notes, held still (the default).
    case song
    /// Zoom in on the keys the song is played on and follow the music up and down the keyboard.
    case auto
    /// Always show all 88 keys.
    case all

    static let storageKey = "keyboardZoom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .song: return "The song's keys"
        case .auto: return "Follow the song"
        case .all: return "All 88 keys"
        }
    }

    var systemImage: String {
        switch self {
        case .song: return "arrow.left.and.right.square"
        case .auto: return "plus.magnifyingglass"
        case .all: return "pianokeys"
        }
    }

    /// The still window from the song's lowest note to its highest, with a couple of keys to spare on each
    /// side and never narrower than two octaves (or `minimumWhiteKeys`).
    static func songLayout(for chart: NoteChart, minimumWhiteKeys: Double) -> KeyboardLayout {
        guard let lowest = chart.notes.map(\.midi).min(), let highest = chart.notes.map(\.midi).max() else {
            return .wholeKeyboard
        }
        let low = KeyboardLayout.extent(of: max(KeyboardLayout.lowestKey, lowest)).lowerBound - KeyboardCamera.padding
        let high = KeyboardLayout.extent(of: min(KeyboardLayout.highestKey, highest)).upperBound + KeyboardCamera.padding
        let width = max(minimumWhiteKeys, high - low)
        // Centre the song's keys when the window is wider than they need.
        return KeyboardLayout(visibleStart: (low + high) / 2 - width / 2, visibleWhiteKeys: width)
    }
}

/// Decides which part of the keyboard is in view while a song plays, like a camera following the music.
///
/// Before the song the whole piano is in view. During the game's lead-in the camera zooms in on the keys the
/// song starts on, then glides up and down the keyboard with the music, widening for passages that spread
/// out rather than cutting notes off. The window is a pure function of the playhead, so it moves as smoothly
/// as the notes do and needs no state:
/// - a note starts to count `lookAhead` beats before it reaches the keyboard and counts fully from half that
///   on, so it is well in view before it arrives (the look-ahead follows the song's tempo but not the speed
///   being played, so speed changes don't make the view breathe);
/// - it counts fully while it sounds, and afterwards until the notes that follow it count fully (so the view
///   holds still through rests), then fades out over half the look-ahead;
/// - the window reaches out to each note's edges as far as the note counts, measured from the weighted
///   centre of the notes that count, so notes fading in and out move the edges gradually.
///
/// Built once per chart (it indexes the notes), then asked every frame. A frame only looks at the notes near
/// the playhead, found by binary search (a chart's notes are sorted by time).
struct KeyboardCamera {
    /// The camera looks this many seconds ahead at the game's usual starting speed, measured in beats of the
    /// song, so further ahead in time when playing slower and less far when faster...
    static let lookAheadSeconds = 3.0
    static let usualSpeed = GameConfiguration().startSpeed
    /// ...within these many beats: at least two, so every note counts fully a beat before it arrives.
    static let lookAheadBeats: ClosedRange<Double> = 2...8
    /// White keys to spare on each side of the notes.
    static let padding = 2.0
    /// The narrowest window: two octaves.
    static let minimumWhiteKeys = 15.0
    /// The zoom from the whole keyboard starts with the game's lead-in (the count-in shows all 88 keys)...
    static let zoomStartSeconds = GameConfiguration().leadInSeconds
    /// ...and is done this long before the first note.
    static let zoomEndSeconds = 1.0

    let chart: NoteChart
    /// Beats ahead of the playhead the camera looks at.
    let lookAhead: Double
    /// Per note, in the chart's order: start and end (beats) and the key's edges (white keys from A0).
    private let times: [Double]
    private let ends: [Double]
    private let lowerEdges: [Double]
    private let upperEdges: [Double]
    /// Per note: when the first note starting once it has ended begins (infinity for the song's last notes).
    private let nextOnsets: [Double]
    private let longestNote: Double
    /// Width of all the song's keys with room to spare (white keys): a steady guide for the keyboard's height.
    let songWhiteKeys: Double

    init(chart: NoteChart) {
        self.chart = chart
        let usualLookAhead = Self.lookAheadSeconds / chart.secondsPerBeat(atSpeed: Self.usualSpeed)
        lookAhead = min(Self.lookAheadBeats.upperBound, max(Self.lookAheadBeats.lowerBound, usualLookAhead))
        let notes = chart.notes
        let times = notes.map(\.time)
        let ends = notes.map { max($0.time, $0.end) }
        let extents = notes.map { KeyboardLayout.extent(of: $0.midi) }
        self.times = times
        self.ends = ends
        lowerEdges = extents.map(\.lowerBound)
        upperEdges = extents.map(\.upperBound)
        nextOnsets = ends.map { end in
            let next = Self.firstIndex(in: times, notBefore: end - 1e-6)
            return next < times.count ? times[next] : .infinity
        }
        longestNote = zip(times, ends).map { $1 - $0 }.max() ?? 0
        let songKeys = (upperEdges.max() ?? 0) - (lowerEdges.min() ?? 0) + 2 * Self.padding
        songWhiteKeys = min(Double(KeyboardLayout.whiteKeyTotal), max(Self.minimumWhiteKeys, songKeys))
    }

    /// The part of the keyboard to show with the playhead at `position` (beats), playing at `secondsPerBeat`
    /// (which times the zoom-in with the lead-in). Wide screens pass a larger `minimumWhiteKeys`, to show more
    /// of the piano rather than giant keys.
    func layout(at position: Double, secondsPerBeat: Double,
                minimumWhiteKeys: Double = KeyboardCamera.minimumWhiteKeys) -> KeyboardLayout {
        guard let firstTime = times.first, position.isFinite, secondsPerBeat.isFinite, secondsPerBeat > 0 else {
            return .wholeKeyboard
        }
        let zoomStart = firstTime - Self.zoomStartSeconds / secondsPerBeat
        let zoomLength = max(1e-6, (Self.zoomStartSeconds - Self.zoomEndSeconds) / secondsPerBeat)
        let zoom = Self.smoothStep((position - zoomStart) / zoomLength)
        guard zoom > 0 else { return .wholeKeyboard }

        // Until the first notes count fully, aim at them.
        let focus = self.focus(at: max(position, firstTime - lookAhead / 2), minimumWhiteKeys: minimumWhiteKeys)
        let total = Double(KeyboardLayout.whiteKeyTotal)
        let focusWidth = focus.upperBound - focus.lowerBound
        guard focusWidth < total - 1e-6 else { return .wholeKeyboard }
        // Zoom like a camera: towards the one point that stays put (as far across the whole keyboard as across
        // the focus), the width shrinking geometrically so the zoom looks steady.
        let width = total * pow(focusWidth / total, zoom)
        let fixedPoint = focus.lowerBound * total / (total - focusWidth)
        return KeyboardLayout(visibleStart: fixedPoint * (1 - width / total), visibleWhiteKeys: width)
    }

    /// The window around the music at `position` (white keys from A0).
    func focus(at position: Double, minimumWhiteKeys: Double) -> ClosedRange<Double> {
        let total = Double(KeyboardLayout.whiteKeyTotal)
        let half = lookAhead / 2
        // A note already played still counts only if it ended less than `half` ago or was still sounding at the
        // latest onset (held through a rest); either way it starts no earlier than that onset less the longest
        // note and `half`. Notes further ahead than the look-ahead don't count yet.
        let started = Self.firstIndex(in: times, after: position)
        let latestOnset = started > 0 ? times[started - 1] : position
        let first = Self.firstIndex(in: times, notBefore: latestOnset - longestNote - half)
        let last = Self.firstIndex(in: times, after: position + lookAhead)
        guard first < last else { return 0...total }

        var weightSum = 0.0
        var centreSum = 0.0
        for i in first..<last {
            let weight = weight(of: i, at: position)
            weightSum += weight
            centreSum += weight * (lowerEdges[i] + upperEdges[i]) / 2
        }
        guard weightSum > 1e-9 else { return 0...total }
        let anchor = centreSum / weightSum
        var low = anchor
        var high = anchor
        for i in first..<last {
            let weight = weight(of: i, at: position)
            guard weight > 0 else { continue }
            low = min(low, anchor + weight * (lowerEdges[i] - anchor))
            high = max(high, anchor + weight * (upperEdges[i] - anchor))
        }
        return Self.window(from: low - Self.padding, to: high + Self.padding, minimumWhiteKeys: minimumWhiteKeys)
    }

    /// How much a note counts (0...1) at `position`.
    private func weight(of i: Int, at position: Double) -> Double {
        let half = lookAhead / 2
        let arriving = Self.smoothStep((position - times[i] + lookAhead) / half)
        guard arriving > 0 else { return 0 }
        let fadeStart = max(ends[i], nextOnsets[i] - half)
        return arriving * (1 - Self.smoothStep((position - fadeStart) / half))
    }

    /// `low...high` widened around its centre to at least `minimumWhiteKeys`, then moved onto the piano.
    static func window(from low: Double, to high: Double, minimumWhiteKeys: Double) -> ClosedRange<Double> {
        let total = Double(KeyboardLayout.whiteKeyTotal)
        var low = low
        var high = high
        let minimum = min(total, minimumWhiteKeys)
        if high - low < minimum {
            let centre = (low + high) / 2
            low = centre - minimum / 2
            high = centre + minimum / 2
        }
        if high - low >= total { return 0...total }
        if low < 0 {
            high -= low
            low = 0
        }
        if high > total {
            low -= high - total
            high = total
        }
        return low...high
    }

    /// 0 below 0, 1 above 1, and an S-curve in between (no sudden starts or stops).
    static func smoothStep(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// Index of the first of the sorted `times` not before `value` (the count if none).
    static func firstIndex(in times: [Double], notBefore value: Double) -> Int {
        var low = 0
        var high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Index of the first of the sorted `times` after `value` (the count if none).
    static func firstIndex(in times: [Double], after value: Double) -> Int {
        var low = 0
        var high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] <= value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
