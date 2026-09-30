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

#if DEBUG
/// A short made-up piece using everything the sheet music draws (for checking it in screenshots): beamed
/// eighths and sixteenths, dotted notes, rests, a tie over the bar line, accidentals in G major, a chord
/// with a second, and notes on ledger lines.
enum NotationTestSong {
    static let title = "Notation test"

    static var score: Score {
        // (MIDI, start beat, beats, hand)
        let notes: [(Int, Double, Double, Hand)] = [
            // Measure 1: eighths, a quarter, four sixteenths.
            (67, 0, 0.5, .right), (69, 0.5, 0.5, .right), (71, 1, 0.5, .right), (72, 1.5, 0.5, .right),
            (74, 2, 1, .right), (76, 3, 0.25, .right), (78, 3.25, 0.25, .right), (79, 3.5, 0.25, .right), (81, 3.75, 0.25, .right),
            (43, 0, 2, .left), (50, 0, 2, .left), (43, 2, 2, .left), (47, 2, 2, .left),
            // Measure 2: dotted quarter + eighth, a half tied into measure 3.
            (71, 4, 1.5, .right), (69, 5.5, 0.5, .right), (67, 6, 3, .right),
            (36, 4, 1, .left), (48, 5, 1, .left), (45, 6, 0.5, .left), (47, 6.5, 0.5, .left), (48, 7, 1, .left),
            // Measure 3: after the tie, a rest, F natural, a chord with a second, a high note on ledger lines.
            (65, 10, 1, .right), (72, 11, 0.5, .right), (74, 11, 0.5, .right), (86, 11.5, 0.5, .right),
            (43, 8, 4, .left),
            // Measure 4: a whole note chord, and a whole-measure rest in the left hand.
            (67, 12, 4, .right), (71, 12, 4, .right), (74, 12, 4, .right),
        ]
        let measures = (0..<4).map {
            ScoreMeasure(index: $0, sourceIndex: $0, number: String($0 + 1), startBeat: Double($0 * 4), lengthBeats: 4,
                         timeSignature: .common)
        }
        return Score(title: title, measures: measures, events: [], initialTempoBPM: 80,
                     notes: notes.map { ScoreNote(midi: $0.0, beat: $0.1, durationBeats: $0.2, hand: $0.3, measureIndex: Int($0.1 / 4)) },
                     keyFifths: 1)
    }
}
#endif
