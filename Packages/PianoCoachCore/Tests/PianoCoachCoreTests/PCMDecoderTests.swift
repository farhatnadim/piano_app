import XCTest
@testable import PianoCoachCore

final class PCMDecoderTests: XCTestCase {
    private func decode(_ data: [UInt8], _ layout: PCMLayout) -> [Float]? {
        data.withUnsafeBytes { PCMDecoder.monoSamples(buffers: [$0], layout: layout) }
    }

    func testBigEndianInt16StereoInterleaved() {
        // Frame 1: L = 0x4000 (0.5), R = 0xC000 (-0.5); frame 2: L = R = 0x2000 (0.25).
        let bytes: [UInt8] = [0x40, 0x00, 0xC0, 0x00, 0x20, 0x00, 0x20, 0x00]
        let layout = PCMLayout(channels: 2, bitsPerChannel: 16, formatFlags: 0x2 | 0x4 | 0x8)
        XCTAssertTrue(layout.isBigEndian)
        XCTAssertFalse(layout.isFloat)
        XCTAssertEqual(decode(bytes, layout), [0, 0.25])
    }

    func testLittleEndianInt16Mono() {
        let bytes: [UInt8] = [0x00, 0x40, 0x00, 0x80]
        let layout = PCMLayout(channels: 1, bitsPerChannel: 16, isFloat: false, isBigEndian: false, isNonInterleaved: false)
        XCTAssertEqual(decode(bytes, layout), [0.5, -1])
    }

    func testFloat32NonInterleaved() {
        let left: [Float] = [0.5, -0.25, 1]
        let right: [Float] = [0.5, 0.25, 0]
        let layout = PCMLayout(channels: 2, bitsPerChannel: 32, formatFlags: 0x1 | 0x8 | 0x20)
        XCTAssertTrue(layout.isNonInterleaved)
        let result = left.withUnsafeBytes { l in
            right.withUnsafeBytes { r in PCMDecoder.monoSamples(buffers: [l, r], layout: layout) }
        }
        XCTAssertEqual(result, [0.5, 0, 0.5])
    }

    func testInt24AndInt32() {
        let int24: [UInt8] = [0x00, 0x00, 0x40, 0x00, 0x00, 0xC0]   // little-endian 0x400000, 0xC00000
        let layout24 = PCMLayout(channels: 1, bitsPerChannel: 24, isFloat: false, isBigEndian: false, isNonInterleaved: false)
        XCTAssertEqual(decode(int24, layout24), [0.5, -0.5])
        let int32: [UInt8] = [0x40, 0x00, 0x00, 0x00]                 // big-endian 0x40000000
        let layout32 = PCMLayout(channels: 1, bitsPerChannel: 32, isFloat: false, isBigEndian: true, isNonInterleaved: false)
        XCTAssertEqual(decode(int32, layout32), [0.5])
    }

    func testUnsupportedLayouts() {
        XCTAssertNil(decode([0, 0], PCMLayout(channels: 1, bitsPerChannel: 8, isFloat: false, isBigEndian: false,
                                              isNonInterleaved: false)))
        XCTAssertNil(decode([0, 0], PCMLayout(channels: 0, bitsPerChannel: 16, isFloat: false, isBigEndian: false,
                                              isNonInterleaved: false)))
        XCTAssertEqual(decode([], PCMLayout(channels: 1, bitsPerChannel: 16, isFloat: false, isBigEndian: false,
                                            isNonInterleaved: false)), [])
    }
}
