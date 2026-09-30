import Foundation

/// Lines up the notes read off a tutorial video's keyboard with the notes heard in its sound, and settles
/// what the video alone can't: which octave the keyboard shows (unless all 88 keys are in view) and the
/// small delay between the picture and the sound.
public enum VideoNoteAligner {
    /// Notes read from the video count when there are at least this many.
    public static let minimumVideoNotes = 12

    /// The video's notes, moved to the octave and moment where they best match `heard` (same clock as
    /// `heard`, give or take `maximumOffset` seconds), with loudness taken from the matching heard note.
    /// Nil when there are too few video notes to trust.
    public static func align(video: [KeyboardVideoReader.VideoNote], heard: [TranscribedNote],
                             octaveKnown: Bool = false, maximumOffset: Double = 0.5) -> [TranscribedNote]? {
        guard video.count >= minimumVideoNotes else { return nil }
        let octaves = octaveKnown ? [0] : Array(-3...3)
        // Most matching notes wins; among equals, the closest fit.
        var best = (octave: 0, offset: 0.0, matches: -1, error: Double.infinity)
        if !heard.isEmpty {
            for octave in octaves {
                for step in stride(from: -maximumOffset, through: maximumOffset, by: 0.01) {
                    let m = matches(video, heard, shift: octave * 12, offset: step)
                    if m.count > best.matches || (m.count == best.matches && m.error < best.error) {
                        best = (octave, step, m.count, m.error)
                    }
                }
            }
        } else {
            best = (0, 0, 0, 0)
        }
        let shift = best.octave * 12
        let sortedHeard = heard.sorted { $0.start < $1.start }
        return video.compactMap { note in
            let midi = note.midi + shift
            guard (21...108).contains(midi) else { return nil }
            let start = note.start + best.offset
            let loudness = nearest(midi: midi, start: start, in: sortedHeard)?.amplitude ?? 0.6
            return TranscribedNote(midi: midi, start: start, end: max(start + 0.05, note.end + best.offset),
                                   amplitude: loudness)
        }
    }

    private static func matches(_ video: [KeyboardVideoReader.VideoNote], _ heard: [TranscribedNote],
                                shift: Int, offset: Double) -> (count: Int, error: Double) {
        var byPitch: [Int: [Double]] = [:]
        for n in heard { byPitch[n.midi, default: []].append(n.start) }
        var count = 0
        var error = 0.0
        for n in video {
            guard let starts = byPitch[n.midi + shift] else { continue }
            let t = n.start + offset
            if let d = starts.map({ abs($0 - t) }).min(), d < 0.08 {
                count += 1
                error += d
            }
        }
        return (count, error)
    }

    private static func nearest(midi: Int, start: Double, in heard: [TranscribedNote]) -> TranscribedNote? {
        heard.filter { $0.midi == midi && abs($0.start - start) < 0.15 }
            .min { abs($0.start - start) < abs($1.start - start) }
    }
}
