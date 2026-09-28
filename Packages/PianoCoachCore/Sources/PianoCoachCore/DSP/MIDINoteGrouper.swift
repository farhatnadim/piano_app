import Foundation

/// Turns MIDI keyboard note-on messages into `NoteOnset`s, grouping keys pressed within a few
/// milliseconds of each other into one chord onset.
///
/// Call `noteOn` for every note-on (velocity > 0) and `flush(now:)` regularly (e.g. every 20 ms);
/// a group is emitted once `window` seconds have passed since its first note.
public struct MIDINoteGrouper: Sendable {
    public var window: Double
    private var groupStart: Double?
    private var groupPitches: [Int] = []
    private var groupMaxVelocity = 0

    public init(window: Double = 0.035) {
        self.window = window
    }

    /// Registers a note-on. Returns the previous group if this note starts a new one.
    public mutating func noteOn(midi: Int, velocity: Int, time: Double) -> NoteOnset? {
        guard velocity > 0 else { return nil }
        var finished: NoteOnset?
        if let start = groupStart, time - start > window {
            finished = makeOnset()
        }
        if groupStart == nil { groupStart = time }
        if !groupPitches.contains(midi) { groupPitches.append(midi) }
        groupMaxVelocity = max(groupMaxVelocity, velocity)
        return finished
    }

    /// Emits the pending group once its window has elapsed.
    public mutating func flush(now: Double) -> NoteOnset? {
        guard let start = groupStart, now - start >= window else { return nil }
        return makeOnset()
    }

    /// Emits the pending group immediately, if any.
    public mutating func flushAll() -> NoteOnset? {
        groupStart == nil ? nil : makeOnset()
    }

    private mutating func makeOnset() -> NoteOnset? {
        guard let start = groupStart, !groupPitches.isEmpty else {
            groupStart = nil
            return nil
        }
        let pitches = groupPitches.sorted()
        let velocity = Float(groupMaxVelocity) / 127
        let onset = NoteOnset(time: start,
                              strength: velocity,
                              levelDB: -60 + 50 * velocity,
                              features: .template(forPitches: pitches),
                              midiPitches: pitches)
        groupStart = nil
        groupPitches.removeAll()
        groupMaxVelocity = 0
        return onset
    }
}
