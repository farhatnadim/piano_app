import PianoCoachCore

/// A built-in easy "Ode to Joy" (Beethoven, public domain) for trying the game without a video.
enum DemoSong {
    static let title = "Ode to Joy (demo)"

    /// Right-hand melody in quarter notes (dotted rhythms as in the classic beginner version) and a
    /// simple left hand, 16 measures of 4/4 at 100 BPM.
    static var chart: NoteChart {
        // (MIDI, beats) per measure.
        let melody: [[(Int, Double)]] = [
            [(64, 1), (64, 1), (65, 1), (67, 1)], [(67, 1), (65, 1), (64, 1), (62, 1)],
            [(60, 1), (60, 1), (62, 1), (64, 1)], [(64, 1.5), (62, 0.5), (62, 2)],
            [(64, 1), (64, 1), (65, 1), (67, 1)], [(67, 1), (65, 1), (64, 1), (62, 1)],
            [(60, 1), (60, 1), (62, 1), (64, 1)], [(62, 1.5), (60, 0.5), (60, 2)],
            [(62, 1), (62, 1), (64, 1), (60, 1)], [(62, 1), (64, 0.5), (65, 0.5), (64, 1), (60, 1)],
            [(62, 1), (64, 0.5), (65, 0.5), (64, 1), (62, 1)], [(60, 1), (62, 1), (55, 2)],
            [(64, 1), (64, 1), (65, 1), (67, 1)], [(67, 1), (65, 1), (64, 1), (62, 1)],
            [(60, 1), (60, 1), (62, 1), (64, 1)], [(62, 1.5), (60, 0.5), (60, 2)],
        ]
        let bass: [[(Int, Double)]] = [
            [(48, 4)], [(43, 4)], [(48, 4)], [(43, 2), (43, 2)],
            [(48, 4)], [(43, 4)], [(48, 4)], [(43, 2), (48, 2)],
            [(43, 2), (48, 2)], [(43, 2), (48, 2)], [(43, 2), (48, 2)], [(48, 2), (43, 2)],
            [(48, 4)], [(43, 4)], [(48, 4)], [(43, 2), (48, 2)],
        ]
        var notes: [ChartNote] = []
        func add(_ measures: [[(Int, Double)]], hand: Hand) {
            for (m, measure) in measures.enumerated() {
                var beat = Double(m * 4)
                for (midi, length) in measure {
                    notes.append(ChartNote(id: 0, midi: midi, time: beat, duration: length, hand: hand))
                    beat += length
                }
            }
        }
        add(melody, hand: .right)
        add(bass, hand: .left)
        return NoteChart(title: title, notes: notes, beatsPerMinute: 100,
                         barLines: (0..<16).map { Double($0 * 4) }, source: .score)
    }

    /// The same song as a score, e.g. to save it as a MIDI file.
    static var score: Score {
        let chart = self.chart
        let measures = (0..<16).map {
            ScoreMeasure(index: $0, sourceIndex: $0, number: String($0 + 1), startBeat: Double($0 * 4), lengthBeats: 4,
                         timeSignature: .common)
        }
        let notes = chart.notes.map {
            ScoreNote(midi: $0.midi, beat: $0.time, durationBeats: $0.duration, hand: $0.hand,
                      measureIndex: min(15, Int($0.time / 4)))
        }
        return Score(title: title, measures: measures, events: [], initialTempoBPM: chart.beatsPerMinute, notes: notes)
    }
}
