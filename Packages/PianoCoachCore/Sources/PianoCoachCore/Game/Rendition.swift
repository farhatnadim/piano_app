import Foundation

/// How much of a song to play: everything, or a simpler version derived from the same notes.
public enum Rendition: String, Codable, CaseIterable, Sendable {
    case full
    case simple
    case melody

    public var displayName: String {
        switch self {
        case .full: return "Everything"
        case .simple: return "Easier"
        case .melody: return "Just the tune"
        }
    }

    /// One line for a child choosing a version.
    public var description: String {
        switch self {
        case .full: return "All the notes, with both hands."
        case .simple: return "One note at a time in each hand."
        case .melody: return "Only the tune, with your right hand."
        }
    }
}

extension NoteChart {
    /// The chart reduced to `kind`. Title, tempo, bar lines, source and key are kept; ids are renumbered.
    ///
    /// - `simple`: the right hand plays only its top voice and the left hand only its lowest note at each
    ///   onset, one note at a time; left-hand notes shorter than a quarter of a beat are dropped.
    /// - `melody`: only the right hand's top voice (or the top voice of everything when there is no right
    ///   hand), all played by the right hand.
    public func rendition(_ kind: Rendition) -> NoteChart {
        let reduced: [ChartNote]
        switch kind {
        case .full:
            return self
        case .simple:
            let right = Self.monophonic(notes.filter { $0.hand == .right }, keep: { $0.max { $0.midi < $1.midi } })
            let left = Self.monophonic(notes.filter { $0.hand == .left && $0.duration >= 0.25 },
                                       keep: { $0.min { $0.midi < $1.midi } })
            reduced = right + left
        case .melody:
            let right = notes.filter { $0.hand == .right }
            reduced = Self.monophonic(right.isEmpty ? notes : right, keep: { $0.max { $0.midi < $1.midi } })
                .map { var n = $0; n.hand = .right; return n }
        }
        return NoteChart(title: title, notes: reduced, beatsPerMinute: beatsPerMinute, barLines: barLines,
                         source: source, keyFifths: keyFifths, videoTimeOfBeatZero: videoTimeOfBeatZero,
                         timeSignatures: timeSignatures)
    }

    /// One note per onset (chosen by `keep`), each cut off where the next one starts: a single line
    /// that one hand can play without holding anything down.
    private static func monophonic(_ notes: [ChartNote], keep: ([ChartNote]) -> ChartNote?) -> [ChartNote] {
        let sorted = notes.sorted { ($0.time, $0.midi) < ($1.time, $1.midi) }
        var line: [ChartNote] = []
        var i = 0
        while i < sorted.count {
            var j = i + 1
            while j < sorted.count, sorted[j].time - sorted[i].time < 1e-3 { j += 1 }
            if let chosen = keep(Array(sorted[i..<j])) {
                if let last = line.indices.last {
                    line[last].duration = min(line[last].duration, chosen.time - line[last].time)
                }
                line.append(chosen)
            }
            i = j
        }
        return line
    }
}
