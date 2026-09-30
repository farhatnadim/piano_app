import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import PianoCoachCore

/// One captured screen frame, read upright (the capture may hand frames over rotated).
struct PixelBufferFrame: VideoFrame {
    private let buffer: CVPixelBuffer
    private let orientation: CGImagePropertyOrientation
    private let bufferWidth: Int
    private let bufferHeight: Int
    private let isBGRA: Bool
    private let base0: UnsafeMutableRawPointer
    private let stride0: Int
    private let base1: UnsafeMutableRawPointer?
    private let stride1: Int
    private let fullRange: Bool
    let width: Int
    let height: Int

    /// Nil for pixel formats it can't read. The buffer must stay locked (read-only) while the frame is used.
    init?(lockedBuffer buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        self.buffer = buffer
        self.orientation = orientation
        bufferWidth = CVPixelBufferGetWidth(buffer)
        bufferHeight = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        switch format {
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            isBGRA = true
            base0 = base
            stride0 = CVPixelBufferGetBytesPerRow(buffer)
            base1 = nil
            stride1 = 0
            fullRange = true
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
            isBGRA = false
            base0 = y
            stride0 = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            base1 = uv
            stride1 = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        default:
            return nil
        }
        let rotated = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        width = rotated ? bufferHeight : bufferWidth
        height = rotated ? bufferWidth : bufferHeight
    }

    func rgb(x: Int, y: Int) -> (r: Float, g: Float, b: Float) {
        // Upright (x, y) -> buffer (bx, by).
        let bx: Int, by: Int
        switch orientation {
        case .right: bx = y; by = bufferHeight - 1 - x
        case .left: bx = bufferWidth - 1 - y; by = x
        case .down: bx = bufferWidth - 1 - x; by = bufferHeight - 1 - y
        default: bx = x; by = y
        }
        let cx = min(bufferWidth - 1, max(0, bx)), cy = min(bufferHeight - 1, max(0, by))
        if isBGRA {
            let p = base0.advanced(by: cy * stride0 + cx * 4).assumingMemoryBound(to: UInt8.self)
            return (Float(p[2]) / 255, Float(p[1]) / 255, Float(p[0]) / 255)
        }
        var luma = Float(base0.load(fromByteOffset: cy * stride0 + cx, as: UInt8.self))
        let uvOffset = (cy / 2) * stride1 + (cx / 2) * 2
        var cb = Float(base1!.load(fromByteOffset: uvOffset, as: UInt8.self)) - 128
        var cr = Float(base1!.load(fromByteOffset: uvOffset + 1, as: UInt8.self)) - 128
        if !fullRange {
            luma = (luma - 16) * (255 / 219)
            cb *= 255 / 224
            cr *= 255 / 224
        }
        let r = luma + 1.402 * cr
        let g = luma - 0.344136 * cb - 0.714136 * cr
        let b = luma + 1.772 * cb
        return (min(1, max(0, r / 255)), min(1, max(0, g / 255)), min(1, max(0, b / 255)))
    }
}

/// Reads the keys a tutorial video lights up, from screen frames arriving on any thread. Frames are read
/// one at a time on a background queue; frames arriving while one is being read are skipped.
final class VideoKeyReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PianoCoach.VideoKeyReader", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var lastFrameTime = -Double.infinity
    private var reader = KeyboardVideoReader()
    /// Where to look for the keyboard: the video's place on screen, 0...1 from the top left.
    private var searchRect: CGRect?

    /// Most frames per second read (tutorial keys stay lit for at least a few frames at this rate).
    private static let maxFramesPerSecond = 30.0

    func setSearchRect(_ rect: CGRect?) {
        lock.withLock { searchRect = rect }
    }

    func reset() {
        queue.sync {
            reader = KeyboardVideoReader()
            lock.withLock {
                busy = false
                lastFrameTime = -Double.infinity
            }
        }
    }

    /// `time` is the frame's `MonotonicClock` time.
    func append(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, time: Double) {
        let accepted: CGRect?? = lock.withLock {
            guard !busy, time - lastFrameTime >= 1 / Self.maxFramesPerSecond else { return nil }
            busy = true
            lastFrameTime = time
            return .some(searchRect)
        }
        guard let rect = accepted else { return }
        queue.async { [self] in
            defer { lock.withLock { busy = false } }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let frame = PixelBufferFrame(lockedBuffer: buffer, orientation: orientation) else { return }
            if reader.layout == nil, let rect {
                reader.settings.searchRect = (Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height))
            }
            reader.read(frame, at: time)
        }
    }

    /// The notes read so far (times on `MonotonicClock`), and whether the whole 88-key piano was in view
    /// (then the octave is certain).
    func notes() -> (notes: [KeyboardVideoReader.VideoNote], fullPiano: Bool, foundKeyboard: Bool) {
        queue.sync {
            let layout = reader.layout
            return (reader.notes(), layout?.keys.count == 88, layout != nil)
        }
    }
}

extension CMSampleBuffer {
    /// The presentation time in `MonotonicClock` seconds (screen captures are stamped on the host clock).
    var hostSeconds: Double {
        CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(self))
    }
}
