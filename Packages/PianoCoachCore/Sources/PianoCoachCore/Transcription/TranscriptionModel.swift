#if canImport(CoreML)
import CoreML
import Foundation

/// Runs Spotify's Basic Pitch note-transcription model (Core ML, Apache License 2.0) on one window of
/// audio at a time. `BasicPitch.transcribe` does everything around it: windowing, stitching, finding notes.
///
/// The model takes `BasicPitch.windowSamples` samples of 22.05 kHz mono audio ("input_2", shape 1 × n × 1)
/// and returns, per frame and piano key, how likely a note is sounding ("Identity_1") and starting
/// ("Identity_2"); "Identity" (pitch contours) isn't needed.
public final class TranscriptionModel: @unchecked Sendable {
    public enum ModelError: LocalizedError {
        case unexpectedOutput

        public var errorDescription: String? { "The note model gave an unexpected answer." }
    }

    private let model: MLModel
    private let lock = NSLock()

    /// Loads a compiled model (.mlmodelc), e.g. the one Xcode builds into the app bundle.
    public init(compiledModelAt url: URL, computeUnits: MLComputeUnits = .all) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: configuration)
    }

    /// Compiles a model package (.mlpackage) first, which takes a moment; for tests and tools.
    public convenience init(packageAt url: URL, computeUnits: MLComputeUnits = .all) throws {
        let compiled = try MLModel.compileModel(at: url)
        try self.init(compiledModelAt: compiled, computeUnits: computeUnits)
    }

    /// Note and onset activations, each row-major frames × 88 keys, for one window of audio.
    public func run(window: [Float]) throws -> (note: [Float], onset: [Float]) {
        let input = try MLMultiArray(shape: [1, NSNumber(value: window.count), 1], dataType: .float32)
        let step = input.strides[1].intValue
        let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: (window.count - 1) * step + 1)
        for i in window.indices { pointer[i * step] = window[i] }
        let features = try MLDictionaryFeatureProvider(dictionary: ["input_2": MLFeatureValue(multiArray: input)])
        let output = try lock.withLock { try model.prediction(from: features) }
        guard let note = output.featureValue(for: "Identity_1")?.multiArrayValue,
              let onset = output.featureValue(for: "Identity_2")?.multiArrayValue,
              note.shape.count >= 2, onset.shape.count >= 2 else { throw ModelError.unexpectedOutput }
        return (Self.rows(of: note), Self.rows(of: onset))
    }

    /// The last two dimensions of `array` (frames × keys) as a row-major array, whatever its strides and type.
    private static func rows(of array: MLMultiArray) -> [Float] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        let rank = shape.count
        let frames = shape[rank - 2], keys = shape[rank - 1]
        let frameStride = strides[rank - 2], keyStride = strides[rank - 1]
        var result = [Float](repeating: 0, count: frames * keys)
        let span = (frames - 1) * frameStride + (keys - 1) * keyStride + 1
        switch array.dataType {
        case .float32:
            let p = array.dataPointer.bindMemory(to: Float.self, capacity: span)
            for t in 0..<frames {
                for k in 0..<keys { result[t * keys + k] = p[t * frameStride + k * keyStride] }
            }
        case .double:
            let p = array.dataPointer.bindMemory(to: Double.self, capacity: span)
            for t in 0..<frames {
                for k in 0..<keys { result[t * keys + k] = Float(p[t * frameStride + k * keyStride]) }
            }
        default:
            // Half floats and anything else: slower, but correct.
            let lead = [NSNumber](repeating: 0, count: rank - 2)
            for t in 0..<frames {
                for k in 0..<keys {
                    result[t * keys + k] = array[lead + [NSNumber(value: t), NSNumber(value: k)]].floatValue
                }
            }
        }
        return result
    }
}
#endif
