import PianoCoachCore

/// "Dawn of the Doors", one theme of the Roblox DOORS medley (Piano Monkeys), read off the tutorial's keyboard. Each theme
/// of the video is its own song, at its own tempo.
enum CleanDoorsDawn {
    static let title = "DOORS: Dawn of the Doors (clean notes)"

    static var song: CleanSong {
        let bars: [CleanSong.Bar] = [
            ([(0, 11, 66)],
             [(0, 13, 47)]),
            ([(1, 11, 73), (12, 4, 74)],
             [(0, 14, 50)]),
            ([(0, 8, 67), (12, 4, 69)],
             [(0, 14, 43)]),
            ([(0, 12, 64), (12, 3, 67)],
             [(0, 14, 45)]),
            ([(0, 12, 66), (12, 4, 71)],
             [(0, 13, 47)]),
            ([(0, 12, 73), (12, 4, 74)],
             [(0, 14, 50)]),
            ([(0, 13, 76), (12, 3, 78)],
             [(0, 14, 43)]),
            ([(0, 8, 81), (12, 2, 83)],
             [(0, 14, 45)]),
            ([(0, 11, 78), (12, 4, 82)],
             [(0, 13, 47)]),
            ([(0, 12, 85), (12, 4, 86)],
             [(0, 14, 50)]),
            ([(0, 12, 79), (12, 4, 81)],
             [(0, 14, 43)]),
            ([(0, 12, 76), (12, 4, 79)],
             [(0, 14, 45)]),
            ([(0, 12, 78), (12, 4, 76)],
             [(0, 13, 47)]),
            ([(0, 10, 74), (12, 4, 73)],
             [(0, 14, 50)]),
            ([(0, 12, 71), (12, 4, 69)],
             [(0, 14, 43)]),
            ([(0, 12, 64), (12, 2, 67)],
             [(0, 14, 45)]),
            ([(0, 11, 66)],
             []),
        ]
        return CleanSong(title: title, videoID: "rsh3rMPkiNQ", keyName: "B minor", keyFifths: 2, tempoBPM: 75,
                         videoTimeOfBeatZero: 1.02, bars: bars)
    }
}
