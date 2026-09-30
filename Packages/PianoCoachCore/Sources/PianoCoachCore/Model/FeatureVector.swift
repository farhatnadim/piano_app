import Foundation

/// Pitch content of a moment of music: an 88-bin "semitone spectrum" (one bin per piano key)
/// plus its 12-bin chroma (pitch-class) folding. Both vectors are L2-normalised so that
/// similarities are plain cosine similarities in 0...1.
///
/// The same representation is used for:
/// * what the microphone heard at a note onset (`OnsetAnalyzer`),
/// * what a learned reference track heard in the video (`TrackRecorder`),
/// * what a score says should sound (`FeatureVector.template(forPitches:)`).
public struct FeatureVector: Codable, Hashable, Sendable {
    /// 88 values, index 0 = A0 (MIDI 21), index 87 = C8 (MIDI 108). L2-normalised (or all zero).
    public var semitones: [Float]
    /// 12 values, index 0 = C. L2-normalised (or all zero).
    public var chroma: [Float]

    public static let semitoneCount = Pitch.pianoKeyCount
    public static let chromaCount = 12

    /// Relative amplitude of harmonics 1...n used when synthesising a template from note names.
    /// Compressed (roughly square-root of a piano's harmonic energy) to match the analyser's compression.
    public static let harmonicWeights: [Float] = [1.0, 0.55, 0.4, 0.3, 0.22, 0.16]

    public static let zero = FeatureVector(uncheckedSemitones: [Float](repeating: 0, count: semitoneCount),
                                           chroma: [Float](repeating: 0, count: chromaCount))

    private init(uncheckedSemitones: [Float], chroma: [Float]) {
        self.semitones = uncheckedSemitones
        self.chroma = chroma
    }

    /// Builds a feature vector from raw (non-negative, already compressed) per-key energies.
    /// `semitones` must have 88 entries; chroma is derived by folding octaves.
    public init(semitones raw: [Float]) {
        precondition(raw.count == FeatureVector.semitoneCount, "semitones must have 88 bins")
        var chroma = [Float](repeating: 0, count: FeatureVector.chromaCount)
        for (k, v) in raw.enumerated() where v > 0 {
            chroma[Pitch.pitchClass(k + Pitch.lowestPianoMIDI)] += v
        }
        self.semitones = FeatureVector.normalized(raw.map { max(0, $0) })
        self.chroma = FeatureVector.normalized(chroma)
    }

    /// Expected features for a set of simultaneously struck MIDI pitches (harmonics included).
    public static func template(forPitches pitches: [Int]) -> FeatureVector {
        var raw = [Float](repeating: 0, count: semitoneCount)
        for midi in pitches {
            for (h, w) in harmonicWeights.enumerated() {
                let semis = 12 * log2(Double(h + 1))
                let target = Int((Double(midi) + semis).rounded())
                if let k = Pitch.pianoKeyIndex(midi: target) { raw[k] += w }
            }
        }
        return FeatureVector(semitones: raw)
    }

    /// True when the vector carries no energy.
    public var isZero: Bool { !semitones.contains { $0 > 0 } }

    /// Whether the sound is a note (or a small chord) rather than noise: a played piano note puts most of
    /// its energy into a few keys — its own and its overtones — while a clap, a cough or talking spreads it
    /// over the whole keyboard. Compares the five strongest keys with the rest (L2-normalised: a note with
    /// its overtones scores about 0.9, wide-band noise well under 0.5).
    public var isPitched: Bool {
        let sorted = semitones.sorted(by: >)
        guard let strongest = sorted.first, strongest > 0 else { return false }
        var top: Float = 0
        for v in sorted.prefix(5) { top += v * v }
        return top >= 0.55
    }

    /// Cosine similarity in 0...1 blending the semitone and chroma views.
    /// `chromaWeight` 0 uses only semitones, 1 only chroma.
    public func similarity(to other: FeatureVector, chromaWeight: Float = 0.5) -> Float {
        let s = FeatureVector.dot(semitones, other.semitones)
        let c = FeatureVector.dot(chroma, other.chroma)
        return max(0, min(1, (1 - chromaWeight) * s + chromaWeight * c))
    }

    // MARK: - Helpers

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<min(a.count, b.count) { sum += a[i] * b[i] }
        return sum
    }

    static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        guard norm > 1e-12 else { return [Float](repeating: 0, count: v.count) }
        return v.map { $0 / norm }
    }
}
