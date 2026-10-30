import PianoCoachCore

/// "The Imperial March" (Star Wars) exactly as the beginner YouTube tutorial `6DAZJa4Kgds` (SimpleSonic) plays
/// it, read off the tutorial's own keyboard: the melody alone, one hand, all 12 bars. Every note falls on a
/// sixteenth (0.1898 s; 79 quarter notes a minute), the first at 1.8 s into the video.
enum CleanImperialMarch {
    static let title = "The Imperial March (clean notes)"

    static var song: CleanSong {
        // Per measure and hand: (sixteenth in the measure, sixteenths long, MIDI).
        let bars: [CleanSong.Bar] = [
            ([(0, 4, 67), (4, 4, 67), (8, 4, 67), (12, 3, 63), (15, 1, 70)],
             []),
            ([(0, 4, 67), (4, 3, 63), (7, 1, 70), (8, 8, 67)],
             []),
            ([(0, 4, 74), (4, 4, 74), (8, 4, 74), (12, 3, 75), (15, 1, 70)],
             []),
            ([(0, 4, 66), (4, 3, 63), (7, 1, 70), (8, 8, 67)],
             []),
            ([(0, 4, 79), (4, 2, 67), (6, 2, 67), (8, 4, 79), (12, 2, 78), (14, 2, 77)],
             []),
            ([(0, 1, 76), (1, 1, 75), (2, 4, 76), (6, 2, 68), (8, 4, 73), (12, 2, 72), (14, 2, 71)],
             []),
            ([(0, 1, 70), (1, 1, 69), (2, 4, 70), (6, 2, 63), (8, 4, 66), (12, 2, 63), (14, 2, 66)],
             []),
            ([(0, 4, 70), (4, 2, 67), (6, 2, 70), (8, 8, 74)],
             []),
            ([(0, 4, 79), (4, 2, 67), (6, 2, 67), (8, 4, 79), (12, 2, 78), (14, 2, 77)],
             []),
            ([(0, 1, 76), (1, 1, 75), (2, 4, 76), (6, 2, 68), (8, 4, 73), (12, 2, 72), (14, 2, 71)],
             []),
            ([(0, 1, 70), (1, 1, 69), (2, 4, 70), (6, 2, 63), (8, 4, 66), (12, 3, 63), (15, 1, 70)],
             []),
            ([(0, 4, 67), (4, 3, 63), (7, 1, 70), (8, 8, 67)],
             []),
        ]
        return CleanSong(title: title, videoID: "6DAZJa4Kgds", keyName: "G minor", keyFifths: -2, tempoBPM: 79,
                         videoTimeOfBeatZero: 1.78, bars: bars)
    }
}
