import Foundation

/// Cuts a score down to a range of beats — to drop a video's spoken introduction, or the applause at
/// the end — so the game only asks for the song itself.
public enum ScoreTrimmer {
    /// `score` from `startBeat` to `endBeat` (quarter-note beats): notes starting in that range are kept
    /// and moved so the first kept beat becomes beat 0; notes reaching past the end are shortened to it.
    /// Measures are laid out again from the start with the time signature in force there, and the events
    /// rebuilt from the notes. Nil when no note is left.
    public static func trim(_ score: Score, from startBeat: Double, to endBeat: Double) -> Score? {
        guard startBeat.isFinite, endBeat.isFinite, endBeat > startBeat else { return nil }
        let start = max(0, startBeat)
        var notes: [ScoreNote] = []
        for note in score.notes where note.beat >= start - 1e-9 && note.beat < endBeat - 1e-9 {
            var kept = note
            kept.beat = max(0, note.beat - start)
            kept.durationBeats = max(1e-3, min(note.durationBeats, endBeat - note.beat))
            notes.append(kept)
        }
        guard !notes.isEmpty else { return nil }
        let signature = score.measureIndex(atBeat: start).map { score.measures[$0].timeSignature }
            ?? score.measures.first?.timeSignature ?? .common
        return score.rebuilt(withNotes: notes, timeSignature: signature)
    }
}

extension Score {
    /// This score with `notes` in place of its own: measures laid out again from beat 0 with
    /// `timeSignature`, events rebuilt from the notes (notes struck within a 960th of a beat share one
    /// onset), everything else kept. For editing a song's notes. Nil when there are no notes.
    public func rebuilt(withNotes notes: [ScoreNote], timeSignature signature: TimeSignature? = nil) -> Score? {
        let notes = notes.filter { $0.beat.isFinite && $0.beat >= 0 }.sorted { ($0.beat, $0.midi) < ($1.beat, $1.midi) }
        guard !notes.isEmpty else { return nil }
        let signature = signature ?? measures.first?.timeSignature ?? .common
        let measureLength = signature.quarterBeatsPerMeasure
        let lastOnset = notes.map(\.beat).max() ?? 0
        let end = notes.map { $0.beat + $0.durationBeats }.max() ?? 0
        var measures: [ScoreMeasure] = []
        var measureStart = 0.0
        repeat {
            let index = measures.count
            measures.append(ScoreMeasure(index: index, sourceIndex: index, number: String(index + 1),
                                         startBeat: measureStart, lengthBeats: measureLength, timeSignature: signature))
            measureStart += measureLength
        } while measureStart <= lastOnset + 1e-9 || measureStart < end - 1.0 / 960

        // Notes struck within a 960th of a beat share one onset.
        var events: [ScoreEvent] = []
        var scoreNotes: [ScoreNote] = []
        var index = 0
        while index < notes.count {
            let beat = notes[index].beat
            var group: [ScoreNote] = []
            while index < notes.count, notes[index].beat - beat < 1.0 / 960 {
                group.append(notes[index])
                index += 1
            }
            let m = min(measures.count - 1, Int((beat / measureLength + 1e-9).rounded(.down)))
            let pitches = Array(Set(group.map(\.midi))).sorted()
            events.append(ScoreEvent(index: events.count, beat: beat, measureIndex: m, sourceMeasureIndex: m,
                                     beatInMeasure: beat - measures[m].startBeat, pitches: pitches, durationBeats: 0))
            scoreNotes += group.map { var n = $0; n.measureIndex = m; return n }
        }
        for k in events.indices {
            events[k].durationBeats = k + 1 < events.count
                ? events[k + 1].beat - events[k].beat
                : scoreNotes.filter { $0.beat == events[k].beat }.map(\.durationBeats).max() ?? 0
        }

        var rebuilt = self
        rebuilt.measures = measures
        rebuilt.events = events
        rebuilt.notes = scoreNotes
        return rebuilt
    }
}
