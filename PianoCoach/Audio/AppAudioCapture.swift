import AVFoundation
import CoreMedia
import Foundation
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

    private let sink: @Sendable ([Float], Double) -> Void
    #if os(macOS)
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "PianoCoach.AppAudioCapture")
    #endif

    init(sink: @escaping @Sendable ([Float], Double) -> Void) {
        self.sink = sink
    }

    #if os(iOS)
    func start() async throws {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else { throw CaptureError.unavailable }
        recorder.isMicrophoneEnabled = false
        try await recorder.startCapture(handler: Self.makeHandler(sink: sink))
    }

    func stop() async {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isRecording else { return }
        try? await recorder.stopCapture()
    }

    /// Built in a static (non-isolated) context: ReplayKit calls it on its own queue.
    private static func makeHandler(sink: @escaping @Sendable ([Float], Double) -> Void)
        -> @Sendable (CMSampleBuffer, RPSampleBufferType, Error?) -> Void {
        { sampleBuffer, type, error in
            guard error == nil, type == .audioApp,
                  let (samples, rate) = SampleBufferAudio.monoSamples(sampleBuffer) else { return }
            sink(samples, rate)
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
        // Only the sound is used; keep the (required) video tiny and slow.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
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
        guard type == .audio, let (samples, rate) = SampleBufferAudio.monoSamples(sampleBuffer) else { return }
        sink(samples, rate)
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
