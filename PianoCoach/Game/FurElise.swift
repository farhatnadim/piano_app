import PianoCoachCore

/// "Für Elise" (Beethoven, public domain) exactly as the easy YouTube tutorial `tOpdCxy7N5M` plays it, read
/// off the tutorial's own keyboard: the theme twice (with its first and second endings), the middle section,
/// and the theme again, with the tutorial's easier left hand (a low note, then one held from two sixteenths
/// later). Every note falls on a sixteenth, a third of a second apart, so the notes line up with the video
/// (the first note, the pickup's E, at 11.91 s; 45 quarter notes a minute).
enum CleanFurElise {
    static let title = "Für Elise (clean notes)"

    static var song: CleanSong {
        // Per measure and hand: (sixteenth in the measure, sixteenths long, MIDI).
        typealias Bar = CleanSong.Bar
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
        let theme: [Bar] = [turn, toA, toB, toC, turn, toA, backToB]
        var bars: [Bar] = [pickup]
        bars += theme
        bars.append(firstEnding)
        bars += theme
        bars.append(secondEnding)
        bars += middle
        bars += theme
        bars += ending

        return CleanSong(title: title, composer: "Ludwig van Beethoven", videoID: "tOpdCxy7N5M", keyName: "A minor",
                         tempoBPM: 45, timeSignature: TimeSignature(beats: 3, beatType: 8), pickupSixteenths: 2,
                         videoTimeOfBeatZero: 11.91, bars: bars)
    }
}
