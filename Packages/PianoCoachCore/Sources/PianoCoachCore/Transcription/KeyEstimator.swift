import Foundation

/// A key worked out from the notes of a song.
public struct EstimatedKey: Hashable, Sendable {
    /// 0...11, C = 0.
    public var tonicPitchClass: Int
    public var isMinor: Bool
    /// Key signature: sharps positive, flats negative (a minor key uses its relative major's signature).
    public var fifths: Int
    /// "G major", "E minor", "B♭ major".
    public var name: String
    /// How much better the winning key fits than the runner-up, 0...1 (small means "could be either").
    public var confidence: Double

    public init(tonicPitchClass: Int, isMinor: Bool, confidence: Double = 1) {
        self.tonicPitchClass = Pitch.pitchClass(tonicPitchClass)
        self.isMinor = isMinor
        fifths = KeyEstimator.fifths(tonicPitchClass: tonicPitchClass, isMinor: isMinor)
        name = KeyEstimator.name(tonicPitchClass: tonicPitchClass, isMinor: isMinor, fifths: fifths)
        self.confidence = confidence
    }
}

/// Finds a song's key by comparing how much each pitch class sounds with the Krumhansl–Kessler key
/// profiles (listener ratings of how well each note fits a key), the standard approach for music
/// without a written key signature.
public enum KeyEstimator {
    static let majorProfile = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// Signature of each major key by tonic pitch class. F♯/G♭ major is written with six flats: flats are
    /// more familiar to young readers, and it keeps the choice consistent.
    private static let majorFifths = [0, -5, 2, -3, 4, -1, -6, 1, -4, 3, -2, 5]

    /// The best-fitting key. Each note counts by how long and how loudly it sounds; songs usually end
    /// (and often start) on the tonic in the bass, which settles close calls such as C major vs A minor.
    public static func estimate(_ notes: [TranscribedNote]) -> EstimatedKey {
        var weights = [Double](repeating: 0, count: 12)
        for n in notes where n.duration > 0 {
            weights[Pitch.pitchClass(n.midi)] += min(n.duration, 2) * max(0.05, n.amplitude)
        }
        return estimate(pitchClassWeights: weights, cadenceBass: cadenceBass(notes))
    }

    /// The best-fitting key for a 12-bin pitch-class histogram (C first). `cadenceBass` lists pitch
    /// classes likely to be the tonic (e.g. the final bass note), each giving that key a small bonus.
    public static func estimate(pitchClassWeights: [Double], cadenceBass: [Int] = []) -> EstimatedKey {
        guard pitchClassWeights.count == 12, pitchClassWeights.contains(where: { $0 > 0 }) else {
            return EstimatedKey(tonicPitchClass: 0, isMinor: false, confidence: 0)
        }
        var scored: [(score: Double, tonic: Int, minor: Bool)] = []
        for minor in [false, true] {
            let profile = minor ? minorProfile : majorProfile
            for tonic in 0..<12 {
                let rotated = (0..<12).map { profile[($0 - tonic + 12) % 12] }
                var score = correlation(pitchClassWeights, rotated)
                score += 0.04 * Double(cadenceBass.filter { Pitch.pitchClass($0) == tonic }.count)
                scored.append((score, tonic, minor))
            }
        }
        // Stable order: equal scores prefer major and the lower tonic.
        scored.sort { $0.score != $1.score ? $0.score > $1.score : ($0.minor ? 1 : 0, $0.tonic) < ($1.minor ? 1 : 0, $1.tonic) }
        let best = scored[0]
        let confidence = max(0, min(1, (best.score - scored[1].score) * 5))
        return EstimatedKey(tonicPitchClass: best.tonic, isMinor: best.minor, confidence: confidence)
    }

    /// Key signature (sharps positive, flats negative) for a key; minor keys use the relative major's.
    public static func fifths(tonicPitchClass: Int, isMinor: Bool) -> Int {
        let pc = Pitch.pitchClass(tonicPitchClass)
        return majorFifths[isMinor ? (pc + 3) % 12 : pc]
    }

    /// Readable key name spelled to match the signature: "G major", "E minor", "B♭ major", "C♯ minor".
    public static func name(tonicPitchClass: Int, isMinor: Bool, fifths: Int) -> String {
        let tonic = NoteSpelling.spell(60 + Pitch.pitchClass(tonicPitchClass), keyFifths: fifths).name
        return "\(tonic) \(isMinor ? "minor" : "major")"
    }

    /// Lowest pitch class of the first and last onsets (with the last counted twice), where a song
    /// most often states its tonic.
    static func cadenceBass(_ notes: [TranscribedNote]) -> [Int] {
        guard let firstStart = notes.map(\.start).min(), let lastStart = notes.map(\.start).max() else { return [] }
        let opening = notes.filter { $0.start - firstStart < 0.1 }.map(\.midi).min()
        let closing = notes.filter { lastStart - $0.start < 0.1 }.map(\.midi).min()
        return [opening, closing, closing].compactMap { $0 }
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in a.indices {
            num += (a[i] - ma) * (b[i] - mb)
            da += (a[i] - ma) * (a[i] - ma)
            db += (b[i] - mb) * (b[i] - mb)
        }
        return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
    }
}
