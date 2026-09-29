// Pre- and post-processing for the Basic Pitch note-transcription model, ported from Spotify's basic-pitch
// (https://github.com/spotify/basic-pitch), Copyright Spotify AB, licensed under the Apache License 2.0.
// Mirrors basic_pitch 0.4.0: inference.py (windowing, unwrap_output) and note_creation.py (note decoding,
// frame times).

import Foundation

/// Everything around the Basic Pitch model except running it: cutting audio into model windows, stitching the
/// per-window outputs back together and decoding the note/onset activations into notes. Results match the
/// Python reference exactly.
///
/// The model takes `windowSamples` mono samples at 22050 Hz and returns, per window, `framesPerWindow` rows of
/// `noteBins` activations (row-major, bin 0 = MIDI 21 = A0) for "note" and "onset" (a third output, pitch
/// contours, is not used here).
public enum BasicPitch {
    /// Sample rate the model expects, in Hz.
    public static let sampleRate = 22050.0
    /// Samples per model frame.
    public static let fftHop = 256
    /// Samples in one model input window (2 s minus one hop).
    public static let windowSamples = 43844
    /// Output frames per model window.
    public static let framesPerWindow = 172
    /// Frames shared by consecutive windows; half of them is dropped at each end of every window.
    public static let overlapFrames = 30
    /// Distance between the starts of consecutive windows, in samples.
    public static let hopSamples = windowSamples - overlapFrames * fftHop
    /// Pitch bins per frame, one per piano key.
    public static let noteBins = 88
    /// MIDI number of bin 0 (A0).
    public static let midiOffset = 21

    /// Frames kept from each window after dropping the overlap at both ends.
    static let keptFramesPerWindow = framesPerWindow - overlapFrames
    /// Zeros added before the audio so the first frame is centred like the others.
    static let leadingPadding = overlapFrames * fftHop / 2
    /// The reference's ANNOTATIONS_FPS (integer division 22050 // 256), used to trim the stitched output.
    static let annotationFramesPerSecond = 86
    /// The reference's ANNOT_N_FRAMES: frames per 2 s training window, used by the frame-time correction.
    static let annotationFramesPerWindow = annotationFramesPerSecond * 2

    // MARK: - Windowing

    /// Number of model windows for `sampleCount` samples of audio (at least one, even for no audio).
    public static func windowCount(forSampleCount sampleCount: Int) -> Int {
        let padded = max(0, sampleCount) + leadingPadding
        return (padded + hopSamples - 1) / hopSamples
    }

    /// Number of frames the stitched output keeps for `sampleCount` samples of audio.
    public static func frameCount(forSampleCount sampleCount: Int) -> Int {
        let exact = Double(max(0, sampleCount)) * (Double(annotationFramesPerSecond) / sampleRate)
        return Int(exact.rounded(.down))
    }

    /// Cuts 22050 Hz mono audio into model input windows: `overlapFrames * fftHop / 2` zeros are added in front,
    /// a window of `windowSamples` starts every `hopSamples`, and the last one is zero-padded. Empty audio still
    /// gives one (silent) window. For long audio prefer `transcribe`, which builds one window at a time.
    public static func windows(for samples: [Float]) -> [[Float]] {
        let count = windowCount(forSampleCount: samples.count)
        var windows: [[Float]] = []
        windows.reserveCapacity(count)
        var buffer = [Float](repeating: 0, count: windowSamples)
        samples.withUnsafeBufferPointer { source in
            for index in 0..<count {
                fillWindow(index, from: source, into: &buffer)
                windows.append(buffer)
            }
        }
        return windows
    }

    static func fillWindow(_ index: Int, from source: UnsafeBufferPointer<Float>, into buffer: inout [Float]) {
        let start = index * hopSamples - leadingPadding
        let lower = max(0, -start)
        let upper = min(windowSamples, source.count - start)
        buffer.withUnsafeMutableBufferPointer { window in
            guard lower < upper else {
                window.update(repeating: 0)
                return
            }
            for i in 0..<lower { window[i] = 0 }
            for i in lower..<upper { window[i] = source[start + i] }
            for i in upper..<windowSamples { window[i] = 0 }
        }
    }

    // MARK: - Stitching

    /// Joins per-window model outputs into one matrix: drops `overlapFrames / 2` frames at each end of every
    /// window, concatenates, and trims to `frameCount(forSampleCount: originalSampleCount)` frames.
    ///
    /// - Parameters:
    ///   - windowOutputs: one output per window, row-major `framesPerWindow` × `width`.
    ///   - width: values per frame (88 for notes and onsets).
    ///   - originalSampleCount: number of audio samples before padding.
    /// - Returns: row-major frames × `width`.
    public static func stitch(_ windowOutputs: [[Float]], width: Int, originalSampleCount: Int) -> [Float] {
        let targetFrames = frameCount(forSampleCount: originalSampleCount)
        var stitched: [Float] = []
        stitched.reserveCapacity(min(targetFrames, windowOutputs.count * keptFramesPerWindow) * width)
        for output in windowOutputs {
            appendKeptFrames(of: output, width: width, to: &stitched)
        }
        let frames = min(targetFrames, stitched.count / max(width, 1))
        stitched.removeLast(stitched.count - frames * width)
        return stitched
    }

    static func appendKeptFrames(of output: [Float], width: Int, to stitched: inout [Float]) {
        precondition(output.count == framesPerWindow * width,
                     "window output must hold \(framesPerWindow) × \(width) values, got \(output.count)")
        let drop = overlapFrames / 2
        stitched.append(contentsOf: output[(drop * width)..<((framesPerWindow - drop) * width)])
    }

    // MARK: - Transcription

    /// Transcribes 22050 Hz mono audio with a Basic Pitch model supplied by the caller.
    ///
    /// `runModel` receives one window of `windowSamples` samples and must return the model's note and onset
    /// outputs for it, each exactly `framesPerWindow` × `noteBins` values, row-major. Windows whose frames would
    /// all be trimmed away are not run (so audio shorter than 257 samples never calls it). `progress` is called
    /// after each window with the fraction done (0...1).
    public static func transcribe(
        samples: [Float],
        settings: DecoderSettings = .init(),
        progress: ((Double) -> Void)? = nil,
        runModel: ([Float]) throws -> (note: [Float], onset: [Float])
    ) rethrows -> [TranscribedNote] {
        let frames = frameCount(forSampleCount: samples.count)
        let needed = min(windowCount(forSampleCount: samples.count),
                         (frames + keptFramesPerWindow - 1) / keptFramesPerWindow)
        guard needed > 0 else {
            progress?(1)
            return []
        }
        var note: [Float] = []
        var onset: [Float] = []
        note.reserveCapacity(needed * keptFramesPerWindow * noteBins)
        onset.reserveCapacity(needed * keptFramesPerWindow * noteBins)
        var buffer = [Float](repeating: 0, count: windowSamples)
        for index in 0..<needed {
            samples.withUnsafeBufferPointer { fillWindow(index, from: $0, into: &buffer) }
            let output = try runModel(buffer)
            appendKeptFrames(of: output.note, width: noteBins, to: &note)
            appendKeptFrames(of: output.onset, width: noteBins, to: &onset)
            progress?(Double(index + 1) / Double(needed))
        }
        note.removeLast(note.count - frames * noteBins)
        onset.removeLast(onset.count - frames * noteBins)
        return notes(frames: note, onsets: onset, frameCount: frames, settings: settings)
    }

    // MARK: - Times

    /// Start time in seconds of stitched frame `frame`, as the reference computes it (`model_frames_to_time`):
    /// `frame * fftHop / sampleRate`, minus a small correction that grows by about 10.3 ms every 172 frames.
    public static func time(ofFrame frame: Int) -> Double {
        let original = Double(frame * fftHop) / sampleRate
        let windowNumber = Double(frame / annotationFramesPerWindow)
        let windowOffset = (Double(fftHop) / sampleRate)
            * (Double(annotationFramesPerWindow) - (Double(windowSamples) / Double(fftHop))) + 0.0018
        return original - windowOffset * windowNumber
    }
}

extension BasicPitch {
    /// Knobs of the note decoder, with the defaults of basic-pitch's `predict()`.
    public struct DecoderSettings: Hashable, Codable, Sendable {
        /// Minimum onset activation (after peak picking) that starts a note.
        public var onsetThreshold: Double
        /// Minimum note activation for a note to stay on.
        public var frameThreshold: Double
        /// Notes this short or shorter (in milliseconds, converted to frames) are dropped.
        public var minimumNoteLengthMs: Double
        /// Also treat sharp rises in the note activations as onsets.
        public var inferOnsets: Bool
        /// After onset-driven notes, keep turning the strongest leftover activations into notes.
        public var melodiaTrick: Bool
        /// Frames below `frameThreshold` tolerated before a note is considered ended.
        public var energyTolerance: Int
        /// Lowest frequency to keep, in Hz; `nil` keeps everything.
        public var minimumFrequency: Double?
        /// Highest frequency to keep, in Hz; `nil` keeps everything.
        public var maximumFrequency: Double?

        public init(
            onsetThreshold: Double = 0.5,
            frameThreshold: Double = 0.3,
            minimumNoteLengthMs: Double = 127.70,
            inferOnsets: Bool = true,
            melodiaTrick: Bool = true,
            energyTolerance: Int = 11,
            minimumFrequency: Double? = nil,
            maximumFrequency: Double? = nil
        ) {
            self.onsetThreshold = onsetThreshold
            self.frameThreshold = frameThreshold
            self.minimumNoteLengthMs = minimumNoteLengthMs
            self.inferOnsets = inferOnsets
            self.melodiaTrick = melodiaTrick
            self.energyTolerance = energyTolerance
            self.minimumFrequency = minimumFrequency
            self.maximumFrequency = maximumFrequency
        }

        /// `minimumNoteLengthMs` in frames, rounded as the reference does (127.70 ms -> 11 frames).
        public var minimumNoteFrames: Int {
            let frames = minimumNoteLengthMs / 1000 * (BasicPitch.sampleRate / Double(BasicPitch.fftHop))
            guard frames.isFinite else { return frames == .infinity ? Int.max : 0 }
            return Int(frames.rounded(.toNearestOrEven))
        }

        /// Pitch bins left after applying the frequency limits (the reference's `constrain_frequency`).
        var allowedBins: Range<Int> {
            var lower = 0
            var upper = BasicPitch.noteBins
            if let hz = maximumFrequency, let bin = BasicPitch.bin(forFrequency: hz) { upper = bin }
            if let hz = minimumFrequency, let bin = BasicPitch.bin(forFrequency: hz) { lower = bin }
            return lower < upper ? lower..<upper : 0..<0
        }
    }

    /// The reference's `round(hz_to_midi(hz) - 21)`, clamped to 0...88 (Python would wrap negative indices,
    /// which only happens for limits below about 26.7 Hz). `nil` for a NaN or negative frequency.
    static func bin(forFrequency hz: Double) -> Int? {
        let midi = 12 * (log2(hz) - log2(440.0)) + 69
        let bin = (midi - Double(midiOffset)).rounded(.toNearestOrEven)
        guard !bin.isNaN else { return nil }
        return Int(min(Double(noteBins), max(0, bin)))
    }
}
