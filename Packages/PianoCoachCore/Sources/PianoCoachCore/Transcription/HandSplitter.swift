import Foundation

/// Decides which hand plays each note of a transcription.
///
/// A fixed split at middle C gets melodies that dip low and accompaniments that climb high wrong, so
/// instead each hand's position is followed through the song. Notes that start together are split
/// between the hands at the point that keeps each hand near where it just was, without stretching it
/// wider than about an octave and a bit (counting keys it is still holding), giving it more than five
/// notes or crossing the hands.
public enum HandSplitter {
    public struct Options: Sendable {
        /// Notes starting within this many seconds of a group's first note are played together.
        public var chordWindow = 0.03
        /// Starting positions (MIDI) of the hands: around G4 and C3.
        public var rightStart = 67.0
        public var leftStart = 48.0
        /// Widest comfortable stretch of one hand, in semitones (an octave plus a tone).
        public var maxSpan = 14
        public var maxNotesPerHand = 5
        /// Keys struck longer ago than this no longer pin a hand in place (the pedal may be holding them).
        public var holdLimit = 1.0
        /// A key released less than this many seconds after the next onset is legato overlap, not held.
        public var legatoOverlap = 0.15
        /// How long (seconds) a played key keeps marking where its hand is.
        public var recentWindow = 1.5
        /// Seconds either side of a moment over which the second pass averages each hand's position.
        public var contextRadius = 2.0

        public init() {}
    }

    /// The hand for each note, in the order given.
    ///
    /// Two passes: the second also knows roughly where each hand is about to go (its average position
    /// around each moment in the first pass), which settles the start of a song or of a new passage.
    public static func assignHands(_ notes: [TranscribedNote], options: Options = Options()) -> [Hand] {
        let groups = notes.onsetGroups(window: options.chordWindow)
        let first = pass(notes, groups: groups, guides: nil, options: options)
        let guides = surroundingPositions(notes, groups: groups, hands: first, radius: options.contextRadius)
        return pass(notes, groups: groups, guides: guides, options: options)
    }

    private static func pass(_ notes: [TranscribedNote], groups: [[Int]], guides: [[Hand: Double]]?,
                             options: Options) -> [Hand] {
        var hands = [Hand](repeating: .right, count: notes.count)
        var tracker = Tracker(options: options)
        for (g, group) in groups.enumerated() {
            let time = notes[group[0]].start
            tracker.guide = guides?[g] ?? [:]
            let split = tracker.bestSplit(group.map { notes[$0].midi }, at: time)
            for (k, index) in group.enumerated() { hands[index] = k < split ? .left : .right }
            tracker.commit(group.map { notes[$0] }, split: split, at: time)
        }
        return hands
    }

    /// For each group, the mean pitch each hand plays within `radius` seconds of it (where it has notes).
    private static func surroundingPositions(_ notes: [TranscribedNote], groups: [[Int]], hands: [Hand],
                                             radius: Double) -> [[Hand: Double]] {
        var result = [[Hand: Double]](repeating: [:], count: groups.count)
        for hand in Hand.allCases {
            let played = notes.indices.filter { hands[$0] == hand }.sorted { notes[$0].start < notes[$1].start }
            var sums = [0.0]
            for i in played { sums.append(sums.last! + Double(notes[i].midi)) }
            var lo = 0, hi = 0
            for (g, group) in groups.enumerated() {
                let time = notes[group[0]].start
                while lo < played.count, notes[played[lo]].start < time - radius { lo += 1 }
                while hi < played.count, notes[played[hi]].start <= time + radius { hi += 1 }
                if hi > lo { result[g][hand] = (sums[hi] - sums[lo]) / Double(hi - lo) }
            }
        }
        return result
    }

    /// Where each hand is and what it is holding down, updated one onset group at a time.
    struct Tracker {
        let options: Options
        var position: [Hand: Double]
        /// Where each hand is on average around the current moment (second pass only).
        var guide: [Hand: Double] = [:]
        var lastTime: [Hand: Double] = [:]
        var recent: [(midi: Int, time: Double, hand: Hand)] = []
        var held: [(midi: Int, start: Double, end: Double, hand: Hand)] = []

        init(options: Options) {
            self.options = options
            position = [.right: options.rightStart, .left: options.leftStart]
        }

        /// Number of notes (from the bottom of `pitches`, sorted ascending) the left hand should take.
        mutating func bestSplit(_ pitches: [Int], at time: Double) -> Int {
            held.removeAll { $0.end <= time + options.legatoOverlap || time - $0.start > options.holdLimit }
            recent.removeAll { time - $0.time > options.recentWindow }
            var best = 0, bestCost = Double.infinity
            for split in 0...pitches.count {
                var c = cost(left: Array(pitches[..<split]), right: Array(pitches[split...]), at: time)
                // Keys a few semitones apart are usually played by one hand.
                if split > 0 && split < pitches.count {
                    c += 1.5 * Double(max(0, 5 - (pitches[split] - pitches[split - 1])))
                }
                if c < bestCost - 1e-9 {
                    best = split
                    bestCost = c
                }
            }
            return best
        }

        func cost(left: [Int], right: [Int], at time: Double) -> Double {
            var total = 0.0
            let heldLeft = held.filter { $0.hand == .left }.map(\.midi)
            let heldRight = held.filter { $0.hand == .right }.map(\.midi)
            for (hand, part, holding) in [(Hand.left, left, heldLeft), (Hand.right, right, heldRight)] where !part.isEmpty {
                total += part.reduce(0) { $0 + distance($1, to: hand, at: time) }
                let struck = part.max()! - part.min()!
                total += 10 * Double(max(0, struck - options.maxSpan))
                let all = part + holding
                let stretch = all.max()! - all.min()!
                total += 0.5 * Double(max(0, stretch - 9)) + 4 * Double(max(0, stretch - options.maxSpan))
                total += 20 * Double(max(0, part.count - options.maxNotesPerHand))
            }
            // Crossing: the right hand below keys the left is holding, or the left above the right's.
            if let low = right.min(), let top = heldLeft.max() { total += 3 * Double(max(0, top - low)) }
            if let high = left.max(), let bottom = heldRight.min() { total += 3 * Double(max(0, high - bottom)) }
            return total
        }

        /// How far a key is from a hand: half from where the hand has been on average lately, half from the
        /// nearest key it played in the last moments (so a melody walking down, or an accompaniment
        /// alternating bass and chord, stays in its hand). A hand that has rested for a while could be
        /// anywhere, so its distance counts for less.
        func distance(_ midi: Int, to hand: Hand, at time: Double) -> Double {
            let centre = guide[hand].map { 0.5 * position[hand]! + 0.5 * $0 } ?? position[hand]!
            var d = abs(Double(midi) - centre)
            if let nearest = recent.lazy.filter({ $0.hand == hand }).map({ abs(midi - $0.midi) }).min() {
                d = 0.5 * d + 0.5 * Double(nearest)
            }
            let rest = time - (lastTime[hand] ?? -.infinity)
            return rest > 2 ? d * 0.75 : d
        }

        mutating func commit(_ group: [TranscribedNote], split: Int, at time: Double) {
            let sorted = group.sorted { $0.midi < $1.midi }
            for (hand, part) in [(Hand.left, Array(sorted[..<split])), (Hand.right, Array(sorted[split...]))]
            where !part.isEmpty {
                let mean = Double(part.reduce(0) { $0 + $1.midi }) / Double(part.count)
                position[hand]! += 0.4 * (mean - position[hand]!)
                lastTime[hand] = time
                recent += part.map { ($0.midi, time, hand) }
                held += part.map { ($0.midi, $0.start, $0.end, hand) }
            }
        }
    }
}
