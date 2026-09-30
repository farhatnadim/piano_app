import PianoCoachCore

/// "Für Elise" (Beethoven, public domain) exactly as the easy YouTube tutorial `tOpdCxy7N5M` plays it, read
/// off the tutorial's own keyboard: the theme twice (with its first and second endings), the middle section,
/// and the theme again, with the tutorial's easier left hand (a low note, then one held from two sixteenths
/// later). Every note falls on a sixteenth, a third of a second apart, so the notes line up with the video.
enum CleanFurElise {
    static let title = "Für Elise (clean notes)"
    static let videoID = "tOpdCxy7N5M"
    /// Seconds into the video where the first note (the pickup's E) is played.
    static let videoTimeOfBeatZero = 11.91
    /// Quarter notes a minute: a sixteenth every third of a second.
    static let tempoBPM = 45.0

    static var score: Score {
        // Per measure and hand: (sixteenth in the measure, sixteenths long, MIDI).
        typealias Bar = (right: [(Int, Int, Int)], left: [(Int, Int, Int)])
        let pickup: Bar = ([(0, 1, 76), (1, 1, 75)], [])                                                      // E D♯
        let turn: Bar = ([(0, 1, 76), (1, 1, 75), (2, 1, 76), (3, 1, 71), (4, 1, 74), (5, 1, 72)], [])         // E D♯ E B D C
        let toA: Bar = ([(0, 2, 69), (3, 1, 60), (4, 1, 64), (5, 1, 69)], [(0, 2, 45), (2, 4, 52)])            // A · C E A
        let toB: Bar = ([(0, 2, 71), (3, 1, 64), (4, 1, 68), (5, 1, 71)], [(0, 2, 40), (2, 4, 52)])            // B · E G♯ B
        let toC: Bar = ([(0, 2, 72), (3, 1, 64), (4, 1, 76), (5, 1, 75)], [(0, 2, 45), (2, 4, 52)])            // C · E E D♯
        let backToB: Bar = ([(0, 2, 71), (3, 1, 64), (4, 1, 72), (5, 1, 71)], [(0, 2, 40), (2, 4, 52)])        // B · E C B
        let firstEnding: Bar = ([(0, 2, 69), (3, 1, 64), (4, 1, 76), (5, 1, 75)], [(0, 6, 45)])                // A · E E D♯
        let secondEnding: Bar = ([(0, 3, 69), (3, 1, 71), (4, 1, 72), (5, 1, 74)], [(0, 2, 45), (2, 4, 52)])   // A · B C D
        let middle: [Bar] = [
            ([(0, 2, 76), (3, 1, 67), (4, 1, 77), (5, 1, 76)], [(0, 2, 48), (2, 4, 55)]),                      // E · G F E
            ([(0, 2, 74), (3, 1, 65), (4, 1, 76), (5, 1, 74)], [(0, 2, 43), (2, 4, 55)]),                      // D · F E D
            ([(0, 2, 72), (3, 1, 64), (4, 1, 74), (5, 1, 72)], [(0, 2, 45), (2, 4, 57)]),                      // C · E D C
            ([(0, 6, 71)], [(0, 6, 40)]),                                                                      // B
            ([(4, 1, 76), (5, 1, 75)], []),                                                                    // … E D♯
        ]
        let ending: [Bar] = [([(0, 6, 69)], [(0, 6, 45)]), ([(0, 6, 81)], [(0, 6, 57)])]                      // A, then A A
        let theme = [turn, toA, toB, toC, turn, toA, backToB]
        let bars = [pickup] + theme + [firstEnding] + theme + [secondEnding] + middle + theme + ending

        let threeEight = TimeSignature(beats: 3, beatType: 8)
        var measures: [ScoreMeasure] = []
        var notes: [ScoreNote] = []
        var start = 0.0
        for (i, bar) in bars.enumerated() {
            let length = i == 0 ? 0.5 : 1.5
            measures.append(ScoreMeasure(index: i, sourceIndex: i, number: String(i), startBeat: start, lengthBeats: length,
                                         timeSignature: threeEight))
            for (hand, list, velocity) in [(Hand.right, bar.right, 0.75), (Hand.left, bar.left, 0.55)] {
                for (at, sixteenths, midi) in list {
                    notes.append(ScoreNote(midi: midi, beat: start + Double(at) / 4, durationBeats: Double(sixteenths) / 4,
                                           hand: hand, measureIndex: i, velocity: velocity))
                }
            }
            start += length
        }
        return Score(title: title, composer: "Ludwig van Beethoven", measures: measures, events: [],
                     initialTempoBPM: tempoBPM, notes: notes.sorted { ($0.beat, $0.midi) < ($1.beat, $1.midi) })
    }
}
