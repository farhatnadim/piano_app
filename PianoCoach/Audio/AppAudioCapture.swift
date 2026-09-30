import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import PianoCoachCore
#if os(iOS)
import ReplayKit
#elseif os(macOS)
import ScreenCaptureKit
#endif

/// Records the sound the device is playing — the YouTube video — straight from the system, without the
/// microphone, so the notes can be written down from a clean copy of the music.
///
/// iPad/iPhone: ReplayKit's in-app capture (the system asks once to allow recording the screen; only the
/// app's own sound is used). Mac: ScreenCaptureKit (the system asks for Screen & System Audio Recording
/// permission); it records the Mac's sound output, so other sounds playing at the same time are heard too.
///
/// Samples arrive on a background queue in whatever format the system uses and are handed to `sink` as
/// mono floats with their sample rate.
final class AppAudioCapture: NSObject, @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case unavailable

        var errorDescription: String? { "Recording the app's sound isn't available here." }
    }

    /// Samples, their rate and the `MonotonicClock` time of the first one.
    typealias AudioSink = @Sendable ([Float], Double, Double) -> Void
    /// A screen frame, how to turn it upright, and its `MonotonicClock` time.
    typealias VideoSink = @Sendable (CVPixelBuffer, CGImagePropertyOrientation, Double) -> Void

    private let sink: AudioSink
    private let videoSink: VideoSink?
    #if os(macOS)
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "PianoCoach.AppAudioCapture")
    private let videoQueue = DispatchQueue(label: "PianoCoach.AppAudioCapture.video")
    #endif

    /// `videoSink`, when given, also receives the screen's frames (to read a tutorial video's keys).
    init(sink: @escaping AudioSink, videoSink: VideoSink? = nil) {
        self.sink = sink
        self.videoSink = videoSink
    }

    #if os(iOS)
    func start() async throws {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else { throw CaptureError.unavailable }
        recorder.isMicrophoneEnabled = false
        try await recorder.startCapture(handler: Self.makeHandler(sink: sink, videoSink: videoSink))
    }

    func stop() async {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isRecording else { return }
        try? await recorder.stopCapture()
    }

    /// Built in a static (non-isolated) context: ReplayKit calls it on its own queue.
    private static func makeHandler(sink: @escaping AudioSink, videoSink: VideoSink?)
        -> @Sendable (CMSampleBuffer, RPSampleBufferType, Error?) -> Void {
        { sampleBuffer, type, error in
            guard error == nil else { return }
            switch type {
            case .audioApp:
                guard let (samples, rate) = SampleBufferAudio.monoSamples(sampleBuffer) else { return }
                sink(samples, rate, sampleBuffer.hostSeconds)
            case .video:
                guard let videoSink, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                var orientation = CGImagePropertyOrientation.up
                if let raw = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil)
                    as? NSNumber, let value = CGImagePropertyOrientation(rawValue: raw.uint32Value) {
                    orientation = value
                }
                videoSink(pixels, orientation, sampleBuffer.hostSeconds)
            default:
                break
            }
        }
    }
    #elseif os(macOS)
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.unavailable }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        if videoSink != nil {
            // Half the display's size is plenty to see which keys light up.
            configuration.width = max(2, display.width)
            configuration.height = max(2, display.height)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        } else {
            // Only the sound is used; keep the (required) video tiny and slow.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if videoSink != nil { try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue) }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }
    #endif
}

#if os(macOS)
extension AppAudioCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio:
            guard let (samples, rate) = SampleBufferAudio.monoSamples(sampleBuffer) else { return }
            sink(samples, rate, sampleBuffer.hostSeconds)
        case .screen:
            guard let videoSink, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            videoSink(pixels, .up, sampleBuffer.hostSeconds)
        default:
            break
        }
    }
}
#endif

/// Reads linear-PCM audio out of a `CMSampleBuffer`.
enum SampleBufferAudio {
    static func monoSamples(_ sampleBuffer: CMSampleBuffer) -> ([Float], Double)? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate > 0 else { return nil }
        var sizeNeeded = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard status == noErr, sizeNeeded > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer)
        guard status == noErr else { return nil }
        return withExtendedLifetime(blockBuffer) {
            let buffers = UnsafeMutableAudioBufferListPointer(list).map {
                UnsafeRawBufferPointer(start: $0.mData, count: Int($0.mDataByteSize))
            }
            let layout = PCMLayout(channels: Int(asbd.mChannelsPerFrame), bitsPerChannel: Int(asbd.mBitsPerChannel),
                                   formatFlags: asbd.mFormatFlags)
            return PCMDecoder.monoSamples(buffers: buffers, layout: layout).map { ($0, asbd.mSampleRate) }
        }
    }
}
