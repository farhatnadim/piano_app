import PianoCoachCore

/// "End Theme", one theme of the Roblox DOORS medley (Piano Monkeys), read off the tutorial's keyboard. Each theme
/// of the video is its own song, at its own tempo.
enum CleanDoorsEndTheme {
    static let title = "DOORS: End Theme (clean notes)"

    static var song: CleanSong {
        let bars: [CleanSong.Bar] = [
            ([(0, 11, 67), (12, 4, 71)],
             [(0, 14, 36)]),
            ([(0, 12, 74), (12, 4, 75)],
             [(0, 13, 39)]),
            ([(0, 12, 68), (12, 4, 70)],
             [(0, 15, 44)]),
            ([(0, 12, 65), (12, 4, 68)],
             [(0, 14, 46)]),
            ([(0, 12, 67), (12, 4, 71)],
             [(0, 14, 36)]),
            ([(0, 12, 74), (12, 4, 75)],
             [(0, 14, 39)]),
            ([(0, 12, 68), (12, 4, 70)],
             [(0, 15, 44)]),
            ([(0, 12, 65), (12, 4, 68)],
             [(0, 14, 46)]),
            ([(0, 12, 67)],
             [(0, 15, 36)]),
        ]
        return CleanSong(title: title, videoID: "rsh3rMPkiNQ", keyName: "C minor", keyFifths: -3, tempoBPM: 69.5,
                         videoTimeOfBeatZero: 329.56, bars: bars)
    }
}
