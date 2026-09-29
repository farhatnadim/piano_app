// Note decoding ported from Spotify's basic-pitch (https://github.com/spotify/basic-pitch), Copyright Spotify AB,
// licensed under the Apache License 2.0: note_creation.py `output_to_notes_polyphonic`, `get_infered_onsets`
// and `constrain_frequency`.

import Foundation

extension BasicPitch {
    /// A decoded note in stitched-frame units: it starts at `startFrame` and ends at `endFrame` (exclusive).
    struct FrameNote: Hashable {
        var startFrame: Int
        var endFrame: Int
        var midi: Int
        var amplitude: Double
    }

    /// Decodes stitched Basic Pitch outputs into notes, exactly like basic-pitch's `model_output_to_notes`.
    ///
    /// - Parameters:
    ///   - frames: the stitched "note" output, row-major `frameCount` × `noteBins`.
    ///   - onsets: the stitched "onset" output, same shape.
    /// - Returns: notes sorted by start, then pitch. Times come from `time(ofFrame:)`; the amplitude is the mean
    ///   note activation over the note (0...1).
    public static func notes(frames: [Float], onsets: [Float], frameCount: Int,
                             settings: DecoderSettings = .init()) -> [TranscribedNote] {
        frameNotes(frames: frames, onsets: onsets, frameCount: frameCount, settings: settings).map {
            TranscribedNote(midi: $0.midi, start: time(ofFrame: $0.startFrame), end: time(ofFrame: $0.endFrame),
                            amplitude: $0.amplitude)
        }
    }

    /// The decoder behind `notes(frames:onsets:frameCount:settings:)`, in frame units, sorted by start frame,
    /// pitch and end frame.
    static func frameNotes(frames: [Float], onsets: [Float], frameCount: Int,
                           settings: DecoderSettings) -> [FrameNote] {
        let bins = noteBins
        precondition(frameCount >= 0 && frames.count == frameCount * bins && onsets.count == frameCount * bins,
                     "frames and onsets must each hold frameCount × \(bins) values")
        precondition(frameCount * bins <= Int(UInt32.max), "too many frames")
        guard frameCount > 0 else { return [] }

        var frames = frames
        var onsets = onsets
        let allowed = settings.allowedBins
        if allowed != 0..<bins {
            zeroBins(outside: allowed, of: &frames)
            zeroBins(outside: allowed, of: &onsets)
        }

        var decoder = NoteDecoder(frames: frames, frameCount: frameCount, settings: settings)
        let starts = onsetCandidates(frames: frames, onsets: onsets, frameCount: frameCount, settings: settings)
        for index in starts.reversed() {
            decoder.addNote(startingAt: index)
        }
        if settings.melodiaTrick {
            decoder.addMelodiaNotes()
        }
        return decoder.notes.sorted {
            ($0.startFrame, $0.midi, $0.endFrame) < ($1.startFrame, $1.midi, $1.endFrame)
        }
    }

    private static func zeroBins(outside allowed: Range<Int>, of matrix: inout [Float]) {
        let bins = noteBins
        matrix.withUnsafeMutableBufferPointer { m in
            var row = 0
            while row < m.count {
                for bin in 0..<bins where !allowed.contains(bin) { m[row + bin] = 0 }
                row += bins
            }
        }
    }

    /// Flat indices (row-major, ascending) of the cells that start a note in the reference: strict local maxima
    /// in time (scipy `argrelmax(axis=0)`, first and last frame excluded) of the onset activations, optionally
    /// combined with rises in the note activations, that reach `onsetThreshold`. As in the reference, when the
    /// threshold is <= 0 every non-peak cell qualifies too (its peak value is 0).
    static func onsetCandidates(frames: [Float], onsets: [Float], frameCount n: Int,
                                settings: DecoderSettings) -> [Int] {
        let bins = noteBins
        let threshold = settings.onsetThreshold
        let zeroQualifies = 0 >= threshold
        var result: [Int] = []
        frames.withUnsafeBufferPointer { x in
            onsets.withUnsafeBufferPointer { o in
                // get_infered_onsets: onset = max(onset, maxOnset * diff / maxDiff), where diff is the smaller of
                // the rises over one and two frames (0 in the first two frames, never negative).
                var maxDiff = 0.0
                var maxOnset = -Float.infinity
                if settings.inferOnsets {
                    for i in 0..<(n * bins) where o[i] > maxOnset { maxOnset = o[i] }
                    if n > 2 {
                        for i in (2 * bins)..<(n * bins) {
                            let d = risingDifference(x, i)
                            if d > maxDiff { maxDiff = d }
                        }
                    }
                    // maxDiff == 0 makes every inferred value 0 / 0 = NaN in the reference: no peaks at all.
                    guard maxDiff > 0 else {
                        if zeroQualifies { result = Array(0..<(n * bins)) }
                        return
                    }
                }
                let infer = settings.inferOnsets
                let scale = Double(maxOnset)
                func fill(_ row: UnsafeMutableBufferPointer<Double>, frame t: Int) {
                    let base = t * bins
                    for f in 0..<bins {
                        let onset = Double(o[base + f])
                        if infer {
                            let d = t >= 2 ? risingDifference(x, base + f) : 0
                            row[f] = max(onset, (scale * d) / maxDiff)
                        } else {
                            row[f] = onset
                        }
                    }
                }
                let rows = UnsafeMutableBufferPointer<Double>.allocate(capacity: 3 * bins)
                defer { rows.deallocate() }
                var previous = UnsafeMutableBufferPointer(rebasing: rows[0..<bins])
                var current = UnsafeMutableBufferPointer(rebasing: rows[bins..<(2 * bins)])
                var next = UnsafeMutableBufferPointer(rebasing: rows[(2 * bins)..<(3 * bins)])
                if n >= 3 {
                    fill(previous, frame: 0)
                    fill(current, frame: 1)
                }
                for t in 0..<n {
                    let interior = t >= 1 && t < n - 1
                    if interior { fill(next, frame: t + 1) }
                    for f in 0..<bins {
                        var peak = 0.0
                        if interior {
                            let v = current[f]
                            if v > previous[f] && v > next[f] { peak = v }
                        }
                        if peak >= threshold { result.append(t * bins + f) }
                    }
                    if interior {
                        (previous, current, next) = (current, next, previous)
                    }
                }
            }
        }
        return result
    }

    /// min(x[t] - x[t-1], x[t] - x[t-2]) clamped at 0, for flat index `i` of frame t >= 2.
    @inline(__always)
    private static func risingDifference(_ x: UnsafeBufferPointer<Float>, _ i: Int) -> Double {
        let value = Double(x[i])
        let d = min(value - Double(x[i - noteBins]), value - Double(x[i - 2 * noteBins]))
        return d < 0 ? 0 : d
    }
}

/// Mutable state of one decoding pass: the leftover note activations ("remaining energy") and the notes found.
private struct NoteDecoder {
    let frames: [Float]
    var remaining: [Float]
    let n: Int
    let frameThreshold: Double
    let minimumFrames: Int
    let tolerance: Int
    var notes: [BasicPitch.FrameNote] = []

    private static let bins = BasicPitch.noteBins
    private static let lastBin = BasicPitch.noteBins - 1

    init(frames: [Float], frameCount: Int, settings: BasicPitch.DecoderSettings) {
        self.frames = frames
        remaining = frames
        n = frameCount
        frameThreshold = settings.frameThreshold
        minimumFrames = settings.minimumNoteFrames
        tolerance = settings.energyTolerance
    }

    /// One iteration of the reference's onset loop for the onset at flat index `index`.
    mutating func addNote(startingAt index: Int) {
        let bins = Self.bins
        let start = index / bins
        let bin = index % bins
        guard start < n - 1 else { return }
        let threshold = frameThreshold
        let tolerance = tolerance
        let n = n
        var end = start + 1
        remaining.withUnsafeBufferPointer { r in
            var k = 0
            while end < n - 1 && k < tolerance {
                if Double(r[end * bins + bin]) < threshold { k += 1 } else { k = 0 }
                end += 1
            }
            end -= k
        }
        guard end - start > minimumFrames else { return }
        remaining.withUnsafeMutableBufferPointer { r in
            for t in start..<end { Self.clear(r, frame: t, bin: bin) }
        }
        notes.append(.init(startFrame: start, endFrame: end, midi: bin + BasicPitch.midiOffset,
                           amplitude: meanActivation(bin: bin, from: start, to: end)))
    }

    /// The reference's melodia loop: repeatedly take the strongest leftover cell (first one in row-major order on
    /// ties, like numpy's argmax), follow it forwards and backwards while the activation stays above the frame
    /// threshold, clear what was followed and keep it as a note if it is long enough.
    ///
    /// Cells only ever change by being cleared to 0, so sorting the cells above the threshold once (strongest
    /// first, then by index) and skipping the ones cleared in the meantime visits exactly the argmax sequence.
    mutating func addMelodiaNotes() {
        let threshold = frameThreshold
        var keys: [UInt64] = []
        var hasNaN = false
        remaining.withUnsafeBufferPointer { r in
            for i in 0..<r.count {
                let v = r[i]
                if v.isNaN { hasNaN = true }
                if Double(v) > threshold {
                    // Ascending key = descending value, then ascending index.
                    keys.append(UInt64(~Self.orderedBits(v)) << 32 | UInt64(i))
                }
            }
        }
        // numpy's max() is NaN when any cell is, which ends the reference's loop before it starts.
        guard !hasNaN else { return }
        keys.sort()

        let bins = Self.bins
        let n = n
        let tolerance = tolerance
        for key in keys {
            let index = Int(key & 0xFFFF_FFFF)
            var found: (start: Int, end: Int, bin: Int)?
            remaining.withUnsafeMutableBufferPointer { r in
                guard Double(r[index]) > threshold else { return }
                let middle = index / bins
                let bin = index % bins
                r[index] = 0

                var i = middle + 1
                var k = 0
                while i < n - 1 && k < tolerance {
                    if Double(r[i * bins + bin]) < threshold { k += 1 } else { k = 0 }
                    Self.clear(r, frame: i, bin: bin)
                    i += 1
                }
                let end = i - 1 - k

                i = middle - 1
                k = 0
                while i > 0 && k < tolerance {
                    if Double(r[i * bins + bin]) < threshold { k += 1 } else { k = 0 }
                    Self.clear(r, frame: i, bin: bin)
                    i -= 1
                }
                let start = i + 1 + k
                found = (start, end, bin)
            }
            guard let note = found, note.end - note.start > minimumFrames else { continue }
            notes.append(.init(startFrame: note.start, endFrame: note.end, midi: note.bin + BasicPitch.midiOffset,
                               amplitude: meanActivation(bin: note.bin, from: note.start, to: note.end)))
        }
    }

    /// Clears a cell and its neighbouring pitch bins.
    @inline(__always)
    private static func clear(_ r: UnsafeMutableBufferPointer<Float>, frame t: Int, bin: Int) {
        let i = t * bins + bin
        r[i] = 0
        if bin < lastBin { r[i + 1] = 0 }
        if bin > 0 { r[i - 1] = 0 }
    }

    private func meanActivation(bin: Int, from start: Int, to end: Int) -> Double {
        frames.withUnsafeBufferPointer { x in
            var sum = 0.0
            for t in start..<end { sum += Double(x[t * Self.bins + bin]) }
            return sum / Double(end - start)
        }
    }

    /// Maps a float's bit pattern to an unsigned integer with the same ordering.
    @inline(__always)
    private static func orderedBits(_ v: Float) -> UInt32 {
        let bits = v.bitPattern
        return bits & 0x8000_0000 != 0 ? ~bits : bits | 0x8000_0000
    }
}
