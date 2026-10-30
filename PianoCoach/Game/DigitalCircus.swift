import PianoCoachCore

/// "The Amazing Digital Circus" theme exactly as the easy YouTube tutorial `5zT1OjgdRME` (Toms Mucenieks) plays
/// it, read off the tutorial's own keyboard: the melody alone, one hand, all 17 bars — in B major, then again a
/// minor third lower from bar 9. Every note falls on a sixteenth (0.1667 s; 90 quarter notes a minute), the first
/// at 1.0 s into the video.
enum CleanDigitalCircus {
    static let title = "The Amazing Digital Circus (clean notes)"

    static var song: CleanSong {
        // Per measure and hand: (sixteenth in the measure, sixteenths long, MIDI).
        let bars: [CleanSong.Bar] = [
            ([(0, 8, 59), (8, 2, 66), (10, 2, 63), (12, 2, 63), (14, 2, 61)],
             []),
            ([(0, 8, 59), (8, 2, 66), (10, 2, 63), (12, 2, 63), (14, 1, 61), (15, 1, 62)],
             []),
            ([(0, 8, 63), (8, 2, 66), (10, 2, 63), (12, 2, 63), (14, 2, 61)],
             []),
            ([(0, 2, 59), (2, 2, 56), (4, 2, 59), (6, 2, 61), (8, 2, 66), (10, 2, 56), (12, 2, 59), (14, 2, 61)],
             []),
            ([(0, 8, 59), (8, 2, 66), (10, 2, 63), (12, 2, 63), (14, 2, 61)],
             []),
            ([(0, 8, 59), (8, 2, 66), (10, 2, 63), (12, 2, 63), (14, 1, 61), (15, 1, 62)],
             []),
            ([(0, 8, 63), (8, 2, 66), (10, 2, 63), (12, 2, 63), (14, 1, 61), (15, 1, 62)],
             []),
            ([(0, 8, 63), (8, 4, 63), (12, 4, 63)],
             []),
            ([(0, 8, 56), (8, 2, 63), (10, 2, 60), (12, 2, 60), (14, 2, 58)],
             []),
            ([(0, 8, 56), (8, 2, 63), (10, 2, 60), (12, 2, 60), (14, 1, 58), (15, 1, 59)],
             []),
            ([(0, 8, 60), (8, 2, 63), (10, 2, 60), (12, 2, 60), (14, 2, 58)],
             []),
            ([(0, 2, 56), (2, 2, 53), (4, 2, 56), (6, 2, 58), (8, 2, 63), (10, 2, 53), (12, 2, 56), (14, 2, 58)],
             []),
            ([(0, 8, 56), (8, 2, 68), (10, 2, 67), (12, 2, 67), (14, 2, 64)],
             []),
            ([(0, 8, 65), (8, 2, 63), (10, 2, 60), (12, 2, 60), (14, 1, 58), (15, 1, 59)],
             []),
            ([(0, 8, 60), (8, 2, 63), (10, 2, 60), (12, 2, 60), (14, 2, 58)],
             []),
            ([(0, 2, 56), (2, 2, 53), (4, 2, 56), (6, 2, 58), (8, 2, 63), (10, 2, 53), (12, 2, 56), (14, 2, 58)],
             []),
            ([(0, 6, 56)],
             []),
        ]
        return CleanSong(title: title, videoID: "5zT1OjgdRME", keyName: "B major", keyFifths: 5, tempoBPM: 90,
                         videoTimeOfBeatZero: 0.98, bars: bars)
    }
}
