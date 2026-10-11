import PianoCoachCore

/// A song whose notes were read off its tutorial video's own keyboard, key by key, and set on the beat — so
/// they are exactly what the video plays, unlike notes the app learns by listening. Each one is added to the
/// library once (`AppModel.addCleanSongsIfNeeded`); to add another, write it like `CleanFurElise` and list it
/// in `all` (the `clean-song` skill does this from a YouTube link).
struct CleanSong {
    /// (sixteenth in the measure, sixteenths long, MIDI). Whole sixteenths, thirds of one for triplets, or
    /// halves and quarters for ornaments.
    typealias Note = (at: Double, length: Double, midi: Int)
    /// One measure's notes per hand.
    typealias Bar = (right: [Note], left: [Note])

    let title: String
    var composer: String?
    let videoID: String
    /// "A minor", for the library.
    let keyName: String
    /// Flats (negative) or sharps in the key signature, for spelling the notes.
    var keyFifths = 0
    /// Quarter notes a minute.
    let tempoBPM: Double
    var timeSignature = TimeSignature.common
    /// Sixteenths in a first measure shorter than the rest (a pickup), or nil.
    var pickupSixteenths: Int?
    /// Seconds into the video where beat 0 (the start of the first measure) falls.
    let videoTimeOfBeatZero: Double
    let bars: [Bar]

    /// Every clean song, oldest first.
    static let all: [CleanSong] = [CleanFurElise.song, CleanTikiTiki.song] + doors

    /// A medley video: each theme is its own song, at its own tempo.
    static let doors: [CleanSong] = [CleanDoorsDawn.song, CleanDoorsElevatorJam.song, CleanDoorsUnhinged.song,
                                     CleanDoorsHereIComeTheme.song, CleanDoorsGuidingLight.song,
                                     CleanDoorsTrailerTheme.song, CleanDoorsEndTheme.song]

    /// Whether other clean songs come from the same video (the themes of a medley).
    var sharesVideo: Bool { Self.all.filter { $0.videoID == videoID }.count > 1 }

    var score: Score {
        let sixteenthsPerBar = Int(timeSignature.quarterBeatsPerMeasure * 4)
        var measures: [ScoreMeasure] = []
        var notes: [ScoreNote] = []
        var start = 0.0
        func addMeasure(sixteenths: Int) {
            let i = measures.count
            let number = pickupSixteenths == nil ? i + 1 : i
            measures.append(ScoreMeasure(index: i, sourceIndex: i, number: String(number), startBeat: start,
                                         lengthBeats: Double(sixteenths) / 4, timeSignature: timeSignature))
            start += Double(sixteenths) / 4
        }
        for (i, bar) in bars.enumerated() {
            let barStart = start
            for (hand, list, velocity) in [(Hand.right, bar.right, 0.75), (Hand.left, bar.left, 0.55)] {
                for note in list {
                    notes.append(ScoreNote(midi: note.midi, beat: barStart + note.at / 4,
                                           durationBeats: note.length / 4, hand: hand, measureIndex: i,
                                           velocity: velocity))
                }
            }
            addMeasure(sixteenths: i == 0 ? pickupSixteenths ?? sixteenthsPerBar : sixteenthsPerBar)
        }
        // Room for a last note held past the final bar line.
        let end = notes.map { $0.beat + $0.durationBeats }.max() ?? 0
        while start < end - 1e-9 { addMeasure(sixteenths: sixteenthsPerBar) }
        return Score(title: title, composer: composer, measures: measures, events: [], initialTempoBPM: tempoBPM,
                     notes: notes.sorted { ($0.beat, $0.midi) < ($1.beat, $1.midi) }, keyFifths: keyFifths)
    }
}
