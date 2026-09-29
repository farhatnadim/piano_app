import Foundation

/// The layout of raw linear-PCM audio, as an `AudioStreamBasicDescription` describes it.
///
/// Screen-recording APIs hand over audio in whatever format the system uses — ReplayKit's app audio is
/// often big-endian 16-bit integers, ScreenCaptureKit's is 32-bit floats — so the app decodes the bytes
/// itself rather than relying on a converter for every case.
public struct PCMLayout: Equatable, Sendable {
    public var channels: Int
    public var bitsPerChannel: Int
    public var isFloat: Bool
    public var isBigEndian: Bool
    /// True when every channel has its own buffer; false when channels alternate in one buffer.
    public var isNonInterleaved: Bool

    public init(channels: Int, bitsPerChannel: Int, isFloat: Bool, isBigEndian: Bool, isNonInterleaved: Bool) {
        self.channels = channels
        self.bitsPerChannel = bitsPerChannel
        self.isFloat = isFloat
        self.isBigEndian = isBigEndian
        self.isNonInterleaved = isNonInterleaved
    }

    /// From `AudioStreamBasicDescription.mFormatFlags` and friends (linear PCM only).
    public init(channels: Int, bitsPerChannel: Int, formatFlags: UInt32) {
        self.init(channels: channels, bitsPerChannel: bitsPerChannel,
                  isFloat: formatFlags & 0x1 != 0,             // kAudioFormatFlagIsFloat
                  isBigEndian: formatFlags & 0x2 != 0,         // kAudioFormatFlagIsBigEndian
                  isNonInterleaved: formatFlags & 0x20 != 0)   // kAudioFormatFlagIsNonInterleaved
    }

    /// Whether `PCMDecoder` can read this layout.
    public var isSupported: Bool {
        channels > 0 && (isFloat ? [32, 64].contains(bitsPerChannel) : [16, 24, 32].contains(bitsPerChannel))
    }
}

/// Turns raw linear-PCM buffers into mono float samples in -1...1.
public enum PCMDecoder {
    /// Mono samples from the buffers of one block of audio: one buffer per channel when the layout is
    /// non-interleaved, otherwise a single buffer. Returns nil for layouts it can't read.
    public static func monoSamples(buffers: [UnsafeRawBufferPointer], layout: PCMLayout) -> [Float]? {
        guard layout.isSupported, !buffers.isEmpty else { return nil }
        let bytes = layout.bitsPerChannel / 8
        if layout.isNonInterleaved {
            let channels = min(layout.channels, buffers.count)
            let frames = buffers.prefix(channels).map { $0.count / bytes }.min() ?? 0
            var mono = [Float](repeating: 0, count: frames)
            let scale = 1 / Float(channels)
            for c in 0..<channels {
                let buffer = buffers[c]
                for i in 0..<frames {
                    mono[i] += sample(in: buffer, at: i * bytes, layout: layout) * scale
                }
            }
            return mono
        }
        let buffer = buffers[0]
        let frameBytes = bytes * layout.channels
        let frames = buffer.count / frameBytes
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(layout.channels)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<layout.channels {
                sum += sample(in: buffer, at: i * frameBytes + c * bytes, layout: layout)
            }
            mono[i] = sum * scale
        }
        return mono
    }

    private static func sample(in buffer: UnsafeRawBufferPointer, at offset: Int, layout: PCMLayout) -> Float {
        switch (layout.isFloat, layout.bitsPerChannel) {
        case (true, 32):
            var bits = buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            bits = layout.isBigEndian ? UInt32(bigEndian: bits) : UInt32(littleEndian: bits)
            return Float(bitPattern: bits)
        case (true, _):
            var bits = buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            bits = layout.isBigEndian ? UInt64(bigEndian: bits) : UInt64(littleEndian: bits)
            return Float(Double(bitPattern: bits))
        case (false, 16):
            var bits = buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            bits = layout.isBigEndian ? UInt16(bigEndian: bits) : UInt16(littleEndian: bits)
            return Float(Int16(bitPattern: bits)) / 32_768
        case (false, 24):
            let b0 = Int32(buffer[offset]), b1 = Int32(buffer[offset + 1]), b2 = Int32(buffer[offset + 2])
            var value = layout.isBigEndian ? (b0 << 16 | b1 << 8 | b2) : (b2 << 16 | b1 << 8 | b0)
            if value & 0x80_0000 != 0 { value -= 0x100_0000 }
            return Float(value) / 8_388_608
        default:
            var bits = buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            bits = layout.isBigEndian ? UInt32(bigEndian: bits) : UInt32(littleEndian: bits)
            return Float(Int32(bitPattern: bits)) / 2_147_483_648
        }
    }
}
