import XCTest
@testable import PianoCoachCore

final class InflateTests: XCTestCase {
    private func fixture(_ base64: String) -> Data {
        Data(base64Encoded: base64, options: .ignoreUnknownCharacters)!
    }

    private func assertInvalid(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Inflate.inflate(Data(bytes)), file: file, line: line) { error in
            guard case InflateError.invalidData = error else {
                return XCTFail("unexpected error \(error)", file: file, line: line)
            }
        }
    }

    // MARK: - CRC-32

    func testCRC32KnownVectors() {
        XCTAssertEqual(CRC32.checksum(Data()), 0)
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)), 0x414F_A339)
        XCTAssertEqual(CRC32.checksum(Data([0x00])), 0xD202_EF8D)
    }

    func testCRC32CanBeComputedIncrementally() {
        let whole = Data("Piano Coach checksums".utf8)
        let first = whole.prefix(7), rest = whole.dropFirst(7)
        let partial = first.withUnsafeBytes { CRC32.update(0, bytes: $0) }
        let combined = rest.withUnsafeBytes { CRC32.update(partial, bytes: $0) }
        XCTAssertEqual(combined, CRC32.checksum(whole))
    }

    // MARK: - Block types (fixtures produced by Python's zlib)

    func testStoredBlock() throws {
        let out = try Inflate.inflate(fixture(InflateFixtures.storedOnly))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), InflateFixtures.sampleText)
    }

    func testFixedHuffmanBlock() throws {
        let compressed = fixture(InflateFixtures.fixedHuffman)
        XCTAssertLessThan(compressed.count, InflateFixtures.sampleText.utf8.count / 2)
        let out = try Inflate.inflate(compressed)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), InflateFixtures.sampleText)
    }

    func testDynamicHuffmanBlockWithCodesLongerThanTheLookupTable() throws {
        // Skewed byte distribution: the literal code has 12-bit codes, exercising the slow decode path.
        let out = try Inflate.inflate(fixture(InflateFixtures.dynamicSkewed))
        XCTAssertEqual(out.count, 6000)
        XCTAssertEqual(CRC32.checksum(out), 0x5D12_4780)
    }

    func testMixedBlocksWithBackReferencesAcrossBlocks() throws {
        // Stored block + dynamic block + (sync-flush) empty stored block + a block that repeats the
        // dynamic block's text by reference + empty stored block + fixed-Huffman final block.
        let out = try Inflate.inflate(fixture(InflateFixtures.mixedBlocks))
        XCTAssertEqual(out.count, 5528)
        XCTAssertEqual(CRC32.checksum(out), 0x16B8_99E0)
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("STORED-BLOCK-PAYLOAD 0123456789"))
        XCTAssertTrue(text.hasSuffix("fixed tail fixed tail fixed tail!"))
        let middle = out.dropFirst(31).dropLast(33)
        XCTAssertEqual(middle.count % 2, 0)
        XCTAssertEqual(middle.prefix(middle.count / 2), middle.suffix(middle.count / 2))
    }

    func testManySmallDynamicBlocks() throws {
        let out = try Inflate.inflate(fixture(InflateFixtures.manySmallBlocks))
        XCTAssertEqual(out.count, 4732)
        XCTAssertEqual(CRC32.checksum(out), 0x50E5_6E54)
    }

    func testMultiMegabyteStreamDecodesQuickly() throws {
        let compressed = fixture(InflateFixtures.largeRepetitive)
        let start = Date()
        let out = try Inflate.inflate(compressed)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(out.count, 2_825_090)
        XCTAssertEqual(CRC32.checksum(out), 0x2253_4853)
        XCTAssertTrue(String(decoding: out.suffix(9000), as: UTF8.self).contains("<399>"))
        XCTAssertLessThan(elapsed, 10, "2.8 MB should inflate in well under a few seconds even in debug builds")
    }

    // MARK: - Hand-built streams

    /// Writes DEFLATE bit fields (LSB first) and Huffman codes (MSB first).
    private struct BitWriter {
        var bytes: [UInt8] = []
        var bitCount = 0

        mutating func bit(_ b: Int) {
            if bitCount % 8 == 0 { bytes.append(0) }
            if b != 0 { bytes[bytes.count - 1] |= UInt8(1 << (bitCount % 8)) }
            bitCount += 1
        }

        mutating func value(_ v: Int, bits n: Int) {
            for i in 0..<n { bit((v >> i) & 1) }
        }

        mutating func code(_ c: Int, length n: Int) {
            for i in stride(from: n - 1, through: 0, by: -1) { bit((c >> i) & 1) }
        }

        /// Fixed-Huffman literal/length code for `symbol` (RFC 1951 §3.2.6).
        mutating func fixedLiteral(_ symbol: Int) {
            switch symbol {
            case 0...143: code(0x30 + symbol, length: 8)
            case 144...255: code(0x190 + symbol - 144, length: 9)
            case 256...279: code(symbol - 256, length: 7)
            default: code(0xC0 + symbol - 280, length: 8)
            }
        }
    }

    func testOverlappingBackReferenceRepeatsBytes() throws {
        var w = BitWriter()
        w.value(1, bits: 1)       // final
        w.value(1, bits: 2)       // fixed Huffman
        w.fixedLiteral(0x61)      // "a"
        w.fixedLiteral(0x62)      // "b"
        w.fixedLiteral(264)       // length 10
        w.code(1, length: 5)      // distance 2
        w.fixedLiteral(284)       // length 227 + 5 extra bits
        w.value(20, bits: 5)      // -> 247
        w.code(0, length: 5)      // distance 1
        w.fixedLiteral(256)       // end of block
        let out = try Inflate.inflate(Data(w.bytes))
        let expected = "ab" + String(repeating: "ab", count: 5) + String(repeating: "b", count: 247)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), expected)
    }

    func testEmptyStreams() throws {
        XCTAssertEqual(try Inflate.inflate(Data([0x03, 0x00])), Data())                   // empty fixed block
        XCTAssertEqual(try Inflate.inflate(Data([0x01, 0x00, 0x00, 0xFF, 0xFF])), Data()) // empty stored block
    }

    func testStoredBlocksAcrossMultipleBlocksAndTrailingBytes() throws {
        // Non-final stored "Hi", final stored "!", then garbage that must be ignored.
        let bytes: [UInt8] = [0x00, 0x02, 0x00, 0xFD, 0xFF, 0x48, 0x69,
                              0x01, 0x01, 0x00, 0xFE, 0xFF, 0x21,
                              0xDE, 0xAD, 0xBE, 0xEF]
        XCTAssertEqual(String(decoding: try Inflate.inflate(Data(bytes)), as: UTF8.self), "Hi!")
    }

    func testInputThatIsASliceOfLargerData() throws {
        let compressed = fixture(InflateFixtures.fixedHuffman)
        let padded = Data([0xAA, 0xBB, 0xCC]) + compressed
        let slice = padded.dropFirst(3)
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertEqual(String(decoding: try Inflate.inflate(slice), as: UTF8.self), InflateFixtures.sampleText)
    }

    // MARK: - Errors

    func testRejectsInvalidBlockType() {
        assertInvalid([0x07])
    }

    func testRejectsStoredLengthMismatch() {
        assertInvalid([0x01, 0x05, 0x00, 0x00, 0x00, 0x41, 0x41, 0x41, 0x41, 0x41])
    }

    func testRejectsEmptyAndTruncatedInput() {
        assertInvalid([])
        assertInvalid([0x01, 0x05, 0x00, 0xFA, 0xFF, 0x41])  // stored block shorter than declared
        let fixed = fixture(InflateFixtures.fixedHuffman)
        assertInvalid(Array(fixed.prefix(fixed.count - 3)))
        let dynamic = fixture(InflateFixtures.dynamicSkewed)
        assertInvalid(Array(dynamic.prefix(dynamic.count / 2)))
        assertInvalid(Array(dynamic.prefix(5)))
        assertInvalid([0x00])  // non-final block with nothing after it
    }

    func testRejectsDistanceBeyondOutput() {
        var w = BitWriter()
        w.value(1, bits: 1)
        w.value(1, bits: 2)
        w.fixedLiteral(0x61)
        w.fixedLiteral(257)       // length 3
        w.code(1, length: 5)      // distance 2, but only 1 byte has been produced
        w.fixedLiteral(256)
        assertInvalid(w.bytes)
    }

    func testRejectsInvalidFixedSymbols() {
        var w = BitWriter()
        w.value(1, bits: 1)
        w.value(1, bits: 2)
        w.fixedLiteral(286)       // lengths 286/287 are not valid symbols
        w.fixedLiteral(256)
        assertInvalid(w.bytes)

        var d = BitWriter()
        d.value(1, bits: 1)
        d.value(1, bits: 2)
        d.fixedLiteral(0x61)
        d.fixedLiteral(257)
        d.code(30, length: 5)     // distance symbols 30/31 are invalid
        d.fixedLiteral(256)
        assertInvalid(d.bytes)
    }

    func testRejectsOutputBeyondLimit() {
        XCTAssertThrowsError(try Inflate.inflate(fixture(InflateFixtures.storedOnly), sizeHint: 10, limit: 100))
        XCTAssertNoThrow(try Inflate.inflate(fixture(InflateFixtures.storedOnly), sizeHint: 10, limit: 165))
    }
}

// MARK: - Fixtures

/// Raw DEFLATE streams generated with Python's zlib (`wbits=-15`).
enum InflateFixtures {
    static let sampleText = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 3) + "Piano practice makes progress!"

    // 165 bytes, CRC-32 0x9b6df1e2
    static let storedOnly = """
        AaUAWv9UaGUgcXVpY2sgYnJvd24gZm94IGp1bXBzIG92ZXIgdGhlIGxhenkgZG9nLiBUaGUgcXVpY2sgYnJvd24gZm94IGp1bXBz
        IG92ZXIgdGhlIGxhenkgZG9nLiBUaGUgcXVpY2sgYnJvd24gZm94IGp1bXBzIG92ZXIgdGhlIGxhenkgZG9nLiBQaWFubyBwcmFj
        dGljZSBtYWtlcyBwcm9ncmVzcyE=
        """

    // 165 bytes, CRC-32 0x9b6df1e2
    static let fixedHuffman = """
        C8lIVSgszUzOVkgqyi/PU0jLr1DIKs0tKFbIL0stUigBSuckVlUqpOSn6ymE0ExxQGZiXr5CQVFicklmcqpCbmJ2ajGQm59elFpc
        rAgA
        """

    // 6000 bytes, CRC-32 0x5d124780
    static let dynamicSkewed = """
        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
        """

    // 5528 bytes, CRC-32 0x16b899e0
    static let mixedBlocks = """
        AB8A4P9TVE9SRUQtQkxPQ0stUEFZTE9BRCAwMTIzNDU2Nzg5hJZrjsIwDISv0qtFJctW6lIE5f4rYbf4mw7wpyGJH2N77DD3c1uX
        YY7lb7o8+rrtxt/ldhr6+jj14T62uXux+3Jpa9sOcwmtlGi3az+fp2W4Tu2ypK2f5bb29BEnu5i1HzJhNzHlxdrGsQiG4RBXkVQU
        jTgNKPW7AxJ8cZsoawThOszZoFO4uiVQwcuEw2Oa9TnYnb9C2CWYC016wnl+w0VeRGwSFcrxDkNoxnfzIrBBBglezel91lukwMMX
        tGdcGwh6R0IriSwZ4Lwmo2q6Cm9Ow+qM/kPX2NpzSZuoU2xSOTYSQK1Hot1AwYZjXSCEDxa2JgcDxBMVSYcaMEgZjUvhTmjX6qSn
        QxsgihoeGywW9C/GgB940mOa5zo13owxMreSSxrSyoNkCOhjI+5GkRw91X0tt5RDYCHEY8OYoeVu0TTCcXk73BPF+paxJ9Oe5JQB
        CA5oMl1PfHyX6h1K51rREBe554tSInOwQJFjXRx1wpnOUuMI47XQEjhrOgmd88O047EpjH1wlOyAFft2VdTSZ+h7ZEZs2FFcDX8f
        /mYu1YrjIja+kd+8lZVJ8ZtaDBks8n9GKo/qZFVUMCWzs3z/AQAA///KGW2rjrZVR9uqo23V0bbqaFt1tK062lYdbauOtlUHaVsV
        AAAA//9Ly6xITVEoSczMUUjDxlQEAA==
        """

    // 2825090 bytes, CRC-32 0x22534853
    static let largeRepetitive = """
        7dtrjiPHtajRqWgIjIh8Aht7LoLdx0eAj2VI8vyv1KyuimSxff9c+lxsrT8tdVeRzEdkZCQXvrjlbz99+eF/vvz4679++fLDr7/9
        +Je//Pjbzz/85b9//uWvP/zXz7/89uWHP37hx1/++eVvf/vp5x9+/cuPf//ywy9ffv3t/sf977/+/V+/vL/J/VV///K3P97onz/9
        +I+fP17+7Xe+vvb+i/ePuv/59qL7Xy4b9vM/fvztx+umfPntX3/9feu+/M8/f778+XVjphdcPvOPf7hv+P0X3rb/65/37Xn7l29H
        4tOm33/+/revH3b/p5/+8a8vv73t8duevP3n/d3u23z//fsv3v///VP+2L7Pn33/pfvuvb3FH5/79u5vH3z/8f3Yff3x+8vvO/Zx
        0u6/+W0X7n/79l6PI+HtON0/9eEd/28n/23D3t/rvsdv/3o512/H4v5Z12P39Yjcf/Dt/d7O7cfZvrz84QR9/dt98+8bd32XaR+e
        jMHrB389eN9O6f0nj0fk267+sdX3DfzOFTBv0dtbTufmMp4/tvD+oq+/97bLX4ff9ap9du6vx/zrG8wbcBnAb//52OJ5eH0MyfcB
        8rFhD6f9Pmh/ulztb6P3/cUf08nXS/X+ystRmeeH723D1zd43OCHK2seCN9Owrf/3t/9bUL56X1gv42Qj6lkupDeDtzlWF/GzNtg
        f/ik6dxN//t2ot8G22Wj5glmnnOmc/j2us/T6fuxv57+71/F962ZhtY8YC5X7+N7PFwN8+maBu3ji6cp6acv8/H/utPvf9x/cP9z
        3r95SM3vf//3t7vXfGinczuNhmkiefvfb+Pq2xF/OyLzxf2xse/z6E+P4+Hh7jVv4rxLl9F2nY0fjtc0JK6n9GEDL+/16bbx6cp+
        H9nXCfjrHPbT8wP5cJw+3ui+ie8fMd/knm/efO09/sazy+vt5jVPStebz3yC7yf1soD5d2foch+5/OXpdfzw6mlKmCazaXQ93g+n
        ieQych+P67Ob6vQJ84Ln7Zfur7gsRS73u8soe9uCt525fsz1Nvo2/i5T//zp0xX8+UY430QfZ6mPF15m/cvF8nnwz+94/537Hj+M
        wWmhetm0x4vm+u/3Vz1OgtN0/LGL8+7Nt9Vpfz5ePE9aT1dN1xE6LX8ep+/LGZ33/O1IzTf1y0zzaY+nMTXNE9Mq/7LMuE49n8f3
        x2m93gPvb3U9yvc9v56q6Tqa9+3Zxz4ekvd7ybSwmI/G95br093v/uvzpXlZJz/MB08Wltebxsfxuyy45lF8GQQfh226IT1/jJiX
        zteDc5mQru//MbDmx4XpBvVkRXLZ8mlmnofy40mf9v56duaj/Di5PsyP373RPdxeLhP8s7F0WRHOU9nDbec6c033zX9z7h+25dPa
        +uGwX58+nmzY5dxNa5vpwvz8kPZ+uV5G9cO5/vR8MV9dlwniY+TNC63HRd485U5b93zhe3m4epyHpln2svvXGeNjevo3D3dPP/a+
        L/PyYLonvO/P2xbMS7N5sH5MKw/3l3lbPy/lLsfu8p3Fx53xycY+XASX33h2LB9uSZ/WopcF52UBMj+mzmPo0+rw6drnciFfHgPn
        CX5arczjZf7C5vKIcx0MH0d+vioeLqznq8vrBDSN0s+Lz6dPih9L2uuwni+Xy14/WyBM8/nl2H0M6PlwfHe5/ezp5n2+nWer66T3
        8O3A9dF7Phvzd0OP3wF8evT8dK9/uJjmten1Mn5b2s3v+PBc/3y6udzonn4fdb1TX0/9w9mdN++61vqYAS//fpnm7lt2WaN+3Iku
        P70+J3wsA6ZZ6HHK+jyi5wXRPBs8TIaXVeLlUf46HJ8tj6/foM178P6y598ezN9DTZfow4U8nZGHp4fLVPSdhe78s2fv9GlFPK1R
        vvNxzx+05i8059P6+Znr01dzn7+BfvwSYX5aeXJZzPPHNHY+7hXz7es6GX3b3+t88/QSebi5XL6/mO4D1yfHj0en+Ynj8qR2HefX
        derHpXFd/Dz57nFaQHz3bnxdX0+n5vEwzKfk4Xx/OsDzzeoy/XycrqdP79dvi6dzc322vjzdP/tS4/Kl11OIeHoRz2f6+rX5w8PF
        tBh+vFo+zzsPE+/n1dM8IT388rwD0xF84g7TSJ8nxseb85NF7rzX83GYn7Uv96frgukpbXz/4e0y539vcp4Hw+ff+bQ6frJTH1+6
        /X8gctESykE5KAfloByUg3JQDspBOSgH5aAclINyUA7KQTkoB+WgHJSDclAOykE5KFc8k4ueUA7KQTkoB+WgHJSDclAOykE5KAfl
        oByUg3JQDspBOSgH5aAclINyUA7KQbnimVyMhHJQDspBOSgH5aAclINyUA7KQTkoB+WgHJSDclAOykE5KAfloByUg3JQDsoVz+Ri
        SSgH5aAclINyUA7KQTkoB+WgHJSDclAOykE5KAfloByUg3JQDspBOSgH5aBc8Uwu1oRyUA7KQTkoB+WgHJSDclAOykE5KAfloByU
        g3JQDspBOSgH5aAclINyUA7KFc/kYksoB+WgHJSDclAOykE5KAfloByUg3JQDspBOSgH5aAclINyUA7KQTkoB+WgXPFMLvaEclAO
        ykE5KAfloByUg3JQDspBOSgH5aAclINyUA7KQTkoB+WgHJSDclAOyhXP5OJIKAfloByUg3JQDspBOSgH5aAclINyUA7KQTkoB+Wg
        HJSDclAOykE5KAfloFzxTC7OhHJQDspBOSgH5aAclINyUA7KQTkoB+WgHJSDclAOykE5KAfloByUg3JQDsoVz+Si3ZLKUTkqR+Wo
        HJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqV7yTi9aSylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+Wo
        HJWjclSOylE5Kle8k4vWk8pROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpXvJOLNpLKUTkqR+WoHJWj
        clSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqV7yTi7YklaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpH
        5agclaNyVK54JxdtTSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpH5ahc8U4u2pZUjspROSpH5agclaNy
        VI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspRueKdXLQ9qRyVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5Kkfl
        qByVo3LFO7loR1I5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5Kkflindy0c6kclSOylE5KkflqByVo3JU
        jspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOyhXv5KLfkspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspR
        OSpXvJOL3pLKUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqV7yTi96TylE5KkflqByVo3JUjspROSpH
        5agclaNyVI7KUTkqR+WoHJWjclSOylE5Kle8k4s+kspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpX
        vJOLviSVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUrngnF31NKkflqByVo3JUjspROSpH5agclaNy
        VI7KUTkqR+WoHJWjclSOylE5KkflqFzxTi76llSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylG54p1c
        9D2pHJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjcsU7uehHUjkqR+WoHJWjclSOylE5KkflqByVo3JU
        jspROSpH5agclaNyVI7KUTkqR+WKd3LRz6RyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KFe/kYtyS
        ylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5Kle8k4vRkspROSpH5agclaNyVI7KUTkqR+WoHJWjclSO
        ylE5KkflqByVo3JUjspROSpXvJOL0ZPKUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqV7yTizGSylE5
        KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5Kle8k4uxJJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNy
        VI7KUTkqR+WoHJWjclSueCcXY00qR+WoHJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoXPFOLsaWVI7KUTkq
        R+WoHJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUbninVyMPakclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JU
        jspROSpH5agclaNyxTu5GEdSOSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpH5Yp3cjHOpHJUjspROSpH
        5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjsoV7+RiuSWVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5
        KkflqByVo3JUrngnF0tLKkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqFzxTi6WnlSOylE5KkflqByV
        o3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylG54p1cLCOpHJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkq
        R+WoHJWjcsU7uViWpHJUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjsoV7+RiWZPKUTkqR+WoHJWjclSO
        ylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqV7yTi2VLKkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5
        KkflqFzxTi6WPakclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyxTu5WI6kclSOylE5KkflqByVo3JU
        jspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOyhXv5GI5k8pROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspR
        OSpXvJOL9ZZUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspRueKdXKwtqRyVo3JUjspROSpH5agclaNy
        VI7KUTkqR+WoHJWjclSOylE5KkflqByVo3LFO7lYe1I5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5Kkfl
        indysY6kclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOyhXr5GJdkspROSpH5agclaNyVI7KUTkqR+Wo
        HJWjclSOylE5KkflqByVo3JUjspROSr3WpVbqRyVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3IvVrmN
        ylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KvdildupHJWjclSOylE5KkflqByVo3JUjspROSpH5agc
        laNyVI7KUTkqR+WoHJWjci9WuYPKUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkq92KVO6kclaNyVI7K
        UTkqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyr1W57UblqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSO
        ylE5KkflqByVe7HKtf9FlYutJ5kjc2SOzJE5MkfmyByZI3NkjsyROTJH5sgcmSNzZI7MkTkyR+bIHJkjc38GmftTt3KxjaRyVI7K
        UTkqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KFe/kYluSylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkq
        R+WoHJWjclSOylE5Kle8k4ttTSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpH5ahc8U4uti2pHJWjclSO
        ylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjcsU7udj2pHJUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5
        KkflqByVo3JUjsoV7+RiO5LKUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqV7yTi+1MKkflqByVo3JU
        jspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqFzxTi72W1I5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWj
        clSOylE5KkflindysbekclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOyhXv5GLvSeWoHJWjclSOylE5
        KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJUr3snFPpLKUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNy
        VI7KUTkqV7yTi31JKkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqFzxTi72NakclaNyVI7KUTkqR+Wo
        HJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyxTu52LekclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWj
        clSOyhXv5GLfk8pROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpXvJOL/UgqR+WoHJWjclSOylE5Kkfl
        qByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoXPFOLvYzqRyVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByV
        o3LFO7k4bknlqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVK97JxdGSylE5KkflqByVo3JUjspROSpH
        5agclaNyVI7KUTkqR+WoHJWjclSOylE5Kle8k4ujJ5WjclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSu
        eCcXx0gqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoXPFOLo4lqRyVo3JUjspROSpH5agclaNyVI7K
        UTkqR+WoHJWjclSOylE5KkflqByVo3LFO7k41qRyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KFe/k
        4tiSylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5Kle8k4tjTypH5agclaNyVI7KUTkqR+WoHJWjclSO
        ylE5KkflqByVo3JUjspROSpH5ahc8U4ujiOpHJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjcsU7uTjO
        pHJUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjsoV7+TivCWVo3JUjspROSpH5agclaNyVI7KUTkqR+Wo
        HJWjclSOylE5KkflqByVo3JUrngnF2dLKkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqFzxTi7OnlSO
        ylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylG54p1cnCOpHJWjclSOylE5KkflqByVo3JUjspROSpH5agc
        laNyVI7KUTkqR+WoHJWjcsU7uTiXpHJUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjsoV7+TiXJPKUTkq
        R+WoHJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqV7yTi3NLKkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+Wo
        HJWjclSOylE5KkflqFzxTi7OPakclaNyVI7KUTkqR+WoHJWjclSOylE5KkflqByVo3JUjspROSpH5agclaNyxTu5OI+kclSOylE5
        KkflqByVo3JUjspROSpH5agclaNyVI7KUTkqR+WoHJWjclSOyhXv5OI8k8pROSpH5agclaNyVI7KUTkqR+WoHJWjclSOylE5Kkfl
        qByVo3JUjspROSpXvJOLdrsllsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWK54KBft1hLLYTksh+Ww
        HJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksVzyUi3brieWwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNy
        WA7LYTksh+WwHJYrHspFu43EclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOyxUP5aLdlsRyWA7LYTks
        h+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LFQ/lot3WxHJYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5
        LIflsByWw3JYDssVD+Wi3bbEclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOyxUP5aLd9sRyWA7LYTks
        h+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LFQ/lot2OxHJYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5
        LIflsByWw3JYDssVD+Wi3c7EclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOyxUP5aK1W2I5LIflsByW
        w3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIfliody0VpLLIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbD
        clgOy2E5LIflsFzxUC5a64nlsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWKx7KRWsjsRyWw3JYDsth
        OSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3LFQ7lobUksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNy
        WA7LYTksh+WwXNVQLlpbE8thOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSz3YpbbsByWw3JYDsthOSyH
        5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3KvZrkdy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgO
        y2E5LPdqljuwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDcq9muRPLYTksh+WwHJbDclgOy2E5LIfl
        sByWw3JYDsthOSyH5bAclsNyWA7LYTks92KW6zcsh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+Ww3KtZ
        rmE5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflXs1y/T/Pcr9/6kg2x+bYHJtjc2yOzbE5Nsfm2Byb
        Y3Nsjs2xOTbH5tgcm2NzbI7NsTk2x+b+VDb3Z6zlovUlsRyWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByW
        w3LFQ7lofU0sh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwXPFQLlrfEsthOSyH5bAclsNyWA7LYTks
        h+WwHJbDclgOy2E5LIflsByWw3JYDsthOSxXPJSL1vfEclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgO
        yxUP5aL1I7EclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyxUO5aP1MLIflsByWw3JYDsthOSyH5bAc
        lsNyWA7LYTksh+WwHJbDclgOy2E5LIflsFzxUC7auCWWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JY
        rngoF220xHJYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDssVD+WijZ5YDsthOSyH5bAclsNyWA7LYTks
        h+WwHJbDclgOy2E5LIflsByWw3JYDsthueKhXLQxEsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSxX
        PJSLNpbEclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOyxUP5aKNNbEclsNyWA7LYTksh+WwHJbDclgO
        y2E5LIflsByWw3JYDsthOSyH5bAclsNyxUO5aGNLLIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsFzx
        UC7a2BPLYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksVzyUizaOxHJYDsthOSyH5bAclsNyWA7LYTks
        h+WwHJbDclgOy2E5LIflsByWw3JYDssVD+WijTOxHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDcsVD
        uWjLLbEclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyxUO5aEtLLIflsByWw3JYDsthOSyH5bAclsNy
        WA7LYTksh+WwHJbDclgOy2E5LIflsFzxUC7a0hPLYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksVzyU
        i7aMxHJYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDssVD+WiLUtiOSyH5bAclsNyWA7LYTksh+WwHJbD
        clgOy2E5LIflsByWw3JYDsthOSyH5YqHctGWNbEclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyxUO5
        aMuWWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYbnioVy0ZU8sh+WwHJbDclgOy2E5LIflsByWw3JY
        DsthOSyH5bAclsNyWA7LYTksh+WwXPFQLtpyJJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDcliueCgX
        bTkTy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LFc8lIu23hLLYTksh+WwHJbDclgOy2E5LIflsByW
        w3JYDsthOSyH5bAclsNyWA7LYTksVzyUi7a2xHJYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDssVD+Wi
        rT2xHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDcsVDuWjrSCyH5bAclsNyWA7LYTksh+WwHJbDclgO
        y2E5LIflsByWw3JYDsthOSyH5bBc8VAu2roklsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWK54KBdt
        XRPLYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksVzyUi7ZuieWwHJbDclgOy2E5LIflsByWw3JYDsth
        OSyH5bAclsNyWA7LYTksh+WwHJYrHspFW/fEclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOyxUP5aKt
        R2I5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIfliody0dYzsRyWw3JYDsthOSyH5bAclsNyWA7LYTks
        h+WwHJbDclgOy2E5LIflsByWw3LFQ7lo2y2xHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDcsVDuWhb
        SyyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bBc8VAu2tYTy2E5LIflsByWw3JYDsthOSyH5bAclsNy
        WA7LYTksh+WwHJbDclgOy2E5LFc8lIu2jcRyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LFQ/lom1L
        Yjksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WKh3LRtjWxHJbDclgOy2E5LIflsByWw3JYDsthOSyH
        5bAclsNyWA7LYTksh+WwHJbDcsVDuWjbllgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2G54qFctG1P
        LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsFzxUC7adiSWw3JYDsthOSyH5bAclsNyWA7LYTksh+Ww
        HJbDclgOy2E5LIflsByWw3JYrngoF207E8thOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSxXPJSLtt8S
        y2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LFc8lIu2t8RyWA7LYTksh+WwHJbDclgOy2E5LIflsByW
        w3JYDsthOSyH5bAclsNyWA7LFQ/lou09sRyWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3LFQ7lo+0gs
        h+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwXPFQLtq+JJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAc
        lsNyWA7LYTksh+WwHJbDcliueCgXbV8Ty2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LFc8lIu2b4nl
        sByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWe20oF23fE8thOSyH5bAclsNyWA7LYTksh+WwHJbDclgO
        y2E5LIflsByWw3JYDsthOSz3YpY7sByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3KvZrkTy2E5LIfl
        sByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LPdiljtuWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH
        5bAclsNyWA7LYblXs1zDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy72a5TqWw3JYDsthOSyH5bAc
        lsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JY7tUsN/5jLPf7hy3J5tgcm2NzbI7NsTk2x+bYHJtjc2yOzbE5Nsfm2BybY3Ns
        js2xOTbH5tjcn9Pm/kS1XLRjTSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bBc8VAu2rEllsNyWA7L
        YTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWK54KBft2BPLYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH
        5bAclsNyWA7LYTksVzyUi3YcieWwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJYrHspFO87EclgOy2E5
        LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOyxUP5aKdt8RyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsth
        OSyH5bAclsNyWA7LFQ/lop0tsRyWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3LFQ7loZ08sh+WwHJbD
        clgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwXPFQLto5EsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIfl
        sByWw3JYDsthOSxXPJSLdi6J5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAcliseykU718RyWA7LYTks
        h+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LFQ/lop1bYjksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAc
        lsNyWA7LYTksh+WKh3LRzj2xHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDcsVDuWjnkVgOy2E5LIfl
        sByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2G54qFctPNMLIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbD
        clgOy2E5LIflsFzxUC767ZZYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthueKhXPRbSyyH5bAclsNy
        WA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bBc8VAu+q0nlsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsth
        OSyH5bAclsNyWK54KBf9NhLLYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksVzyUi35bEsthOSyH5bAc
        lsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSxXPJSLflsTy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+Ww
        HJbDclgOy2E5LFc8lIt+2xLLYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksVzyUi37bE8thOSyH5bAc
        lsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSxXPJSLfjsSy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+Ww
        HJbDclgOy2E5LFc8lIt+OxPLYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksVzyUi95uieWwHJbDclgO
        y2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJYrHspFby2xHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7L
        YTksh+WwHJbDcsVDueitJ5bDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDcliueCgXvY3EclgOy2E5LIfl
        sByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOyxUP5aK3JbEclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsth
        OSyH5bAclsNyxUO56G1NLIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsFzxUC562xLLYTksh+WwHJbD
        clgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksVzyUi972xHJYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIfl
        sByWw3JYDssVD+WityOxHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDcsVDuejtTCyH5bAclsNyWA7L
        YTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bBc8VAuer8llsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH
        5bAclsNyWK54KBe9t8RyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LFQ/loveeWA7LYTksh+WwHJbD
        clgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYbnioVz0PhLLYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNy
        WA7LYTksVzyUi96XxHJYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDssVD+Wi9zWxHJbDclgOy2E5LIfl
        sByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDcsVDueh9SyyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsth
        OSyH5bBc8VAuet8Ty2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LFc8lIvej8RyWA7LYTksh+WwHJbD
        clgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LFQ/lovczsRyWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIfl
        sByWw3LFQ7no45ZYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthueKhXPTREsthOSyH5bAclsNyWA7L
        YTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSxXPJSLPnpiOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsth
        OSyH5YqHctHHSCyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bBc8VAu+lgSy2E5LIflsByWw3JYDsth
        OSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LFc8lIs+1sRyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNy
        WA7LFQ/loo8tsRyWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3LFQ7noY08sh+WwHJbDclgOy2E5LIfl
        sByWw3JYDsthOSyH5bAclsNyWA7LYTksh+Ww3H8olIs+jsRyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNy
        WA7LvZjlTiyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bDci1luuWE5LIflsByWw3JYDsthOSyH5bAc
        lsNyWA7LYTksh+WwHJbDclgOy2E5LIflXs1yDcthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSz3apbr
        WA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYblXs9zAclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNy
        WA7LYTksh+WwHJbDclgOy72a5ZZXs9zvn7Emm2NzbI7NsTk2x+bYHJtjc2yOzbE5Nsfm2BybY3Nsjs2xOTbH5tgcm2Nzf3Kbq1/L
        RV+2xHJYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDssVD+WiL3tiOSyH5bAclsNyWA7LYTksh+WwHJbD
        clgOy2E5LIflsByWw3JYDsthOSyH5YqHctGXI7EclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyxUO5
        6MuZWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYbnioVz09ZZYDsthOSyH5bAclsNyWA7LYTksh+Ww
        HJbDclgOy2E5LIflsByWw3JYDsthueKhXPS1JZbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDcliueCgX
        fe2J5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAcliseykVfR2I5LIflsByWw3JYDsthOSyH5bAclsNy
        WA7LYTksh+WwHJbDclgOy2E5LIfliody0dclsRyWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3LFQ7no
        65pYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthueKhXPR1SyyH5bAclsNyWA7LYTksh+WwHJbDclgO
        y2E5LIflsByWw3JYDsthOSyH5bBc8VAu+ronlsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWK54KBd9
        PRLLYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksVzyUi76eieWwHJbDclgOy2E5LIflsByWw3JYDsth
        OSyH5bAclsNyWA7LYTksh+WwHJYrHspF326J5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAcliseykXf
        WmI5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIfliody0beeWA7LYTksh+WwHJbDclgOy2E5LIflsByW
        w3JYDsthOSyH5bAclsNyWA7LYbnioVz0bSSWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYrngoF31b
        EsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSxXPJSLvq2J5bAclsNyWA7LYTksh+WwHJbDclgOy2E5
        LIflsByWw3JYDsthOSyH5bAcliseykXftsRyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LFQ/lom97
        Yjksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WKh3LRtyOxHJbDclgOy2E5LIflsByWw3JYDsthOSyH
        5bAclsNyWA7LYTksh+WwHJbDcsVDuejbmVgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2G54qFc9P2W
        WA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYbnioVz0vSWWw3JYDsthOSyH5bAclsNyWA7LYTksh+Ww
        HJbDclgOy2E5LIflsByWw3JYrngoF33vieWwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJYrHspF30di
        OSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5YqHctH3JbEclsNyWA7LYTksh+WwHJbDclgOy2E5LIfl
        sByWw3JYDsthOSyH5bAclsNyxUO56PuaWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYbnioVz0fUss
        h+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwXPFQLvq+J5bDclgOy2E5LIflsByWw3JYDsthOSyH5bAc
        lsNyWA7LYTksh+WwHJbDcliueCgXfT8Sy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LFc8lIu+n4nl
        sByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWKx7KRT9uieWwHJbDclgOy2E5LIflsByWw3JYDsthOSyH
        5bAclsNyWA7LYTksh+WwHJYrHspFP1piOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5YqHctGPnlgO
        y2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2G54qFc9GMklsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByW
        w3JYDsthOSyH5bAclsNyWK54KBf9WBLLYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksVzyUi36sieWw
        HJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJYrHspFP7bEclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNy
        WA7LYTksh+WwHJbDclgOyxUP5aIfe2I5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIfliody0Y8jsRyW
        w3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3LFQ7nox5lYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgO
        y2E5LIflsByWw3JYDsthueKhXPTzllgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2G54qFc9LMllsNy
        WA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWK54KBf97InlsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+Ww
        HJbDclgOy2E5LIflsByWKx7KRT9HYjksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WKh3LRzyWxHJbD
        clgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDcsVDuejnmlgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7L
        YTksh+WwHJbDclgOy2G54qFc9HNLLIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsFzxUC76uSeWw3JY
        DsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYrngoF/08EsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5
        LIflsByWw3JYDsthOSz3nw7lop9nYjksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+VeynLjdsNyWA7L
        YTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LvZrlGpbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7L
        YTksh+WwHJbDclju1SzXsRyWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3KvZrmB5bAclsNyWA7LYTks
        h+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclns1yy1YDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JY
        DsthuVez3Poilvv9rbdkc2yOzbE5Nsfm2BybY3Nsjs2xOTbH5tgcm2NzbI7NsTk2x+bYHJtjc2yOzd2vyLK1XIzbnlgOy2E5LIfl
        sByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2G54qFcjNuRWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH
        5bAclsNyWA7LYbnioVyM25lYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthueKhXIx2SyyH5bAclsNy
        WA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bBc8VAuRmuJ5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JY
        DsthOSyH5bAcliseysVoPbEclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyxUO5GG0klsNyWA7LYTks
        h+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWK54KBejLYnlsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgO
        y2E5LIflsByWKx7KxWhrYjksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WKh3Ix2pZYDsthOSyH5bAc
        lsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthueKhXIy2J5bDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTks
        h+WwHJbDcliueCgXox2J5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAcliseysVoZ2I5LIflsByWw3JY
        DsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIfliodyMfotsRyWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5
        LIflsByWw3LFQ7kYvSWWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYrngoF6P3xHJYDsthOSyH5bAc
        lsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDssVD+Vi9JFYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByW
        w3JYDsthueKhXIy+JJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDcliueCgXo6+J5bAclsNyWA7LYTks
        h+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAcliseysXoW2I5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgO
        y2E5LIfliodyMfqeWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYbnioVyMfiSWw3JYDsthOSyH5bAc
        lsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYrngoF6OfieWwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTks
        h+WwHJYrHsrFGLfEclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOyxUP5WKMllgOy2E5LIflsByWw3JY
        DsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2G54qFcjNETy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgO
        y2E5LFc8lIsxRmI5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIfliodyMcaSWA7LYTksh+WwHJbDclgO
        y2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYbnioVyMsSaWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByW
        w3JYrngoF2NsieWwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJYrHsrFGHtiOSyH5bAclsNyWA7LYTks
        h+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5YqHcjHGkVgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgO
        y2G54qFcjHEmlsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWK54KBdjuSWWw3JYDsthOSyH5bAclsNy
        WA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYrngoF2NpieWwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+Ww
        HJYrHsrFWHpiOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5YqHcjGWkVgOy2E5LIflsByWw3JYDsth
        OSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2G54qFcjGVJLIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIfl
        sFzxUC7GsiaWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYrngoF2PZEsthOSyH5bAclsNyWA7LYTks
        h+WwHJbDclgOy2E5LIflsByWw3JYDsthOSxXPJSLseyJ5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAc
        liseysVYjsRyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LFQ/lYixnYjksh+WwHJbDclgOy2E5LIfl
        sByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WKh3Ix1ltiOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH
        5YqHcjHWllgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2G54qFcjLUnlsNyWA7LYTksh+WwHJbDclgO
        y2E5LIflsByWw3JYDsthOSyH5bAclsNyWK54KBdjHYnlsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByW
        Kx7KxViXxHJYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDssVD+VirGtiOSyH5bAclsNyWA7LYTksh+Ww
        HJbDclgOy2E5LIflsByWw3JYDsthOSyH5YqHcjHWLbEclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNy
        xUO5GOueWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYbnioVyM9Ugsh+WwHJbDclgOy2E5LIflsByW
        w3JYDsthOSyH5bAclsNyWA7LYTksh+WwXPFQLsZ6JpbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclju
        fy2Ui7HdEsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSz3YpZrWA7LYTksh+WwHJbDclgOy2E5LIfl
        sByWw3JYDsthOSyH5bAclsNyWA7LYblXs1zHclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy72a5QaW
        w3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JY7tUst2A5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTks
        h+WwHJbDclgOy2E5LIflXs1yK5bDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclju1Sy3/b9lud/fcU82
        x+bYHJtjc2yOzbE5Nsfm2BybY3Nsjs2xOTbH5tgcm2NzbI7NsTk2x+bY3IPNVavlYmxHYjksh+WwHJbDclgOy2E5LIflsByWw3JY
        DsthOSyH5bAclsNyWA7LYTksh+WKh3IxtjOxHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDcsVDuRj7
        LbEclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyxUO5GHtLLIflsByWw3JYDsthOSyH5bAclsNyWA7L
        YTksh+WwHJbDclgOy2E5LIflsFzxUC7G3hPLYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksVzyUi7GP
        xHJYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDssVD+Vi7EtiOSyH5bAclsNyWA7LYTksh+WwHJbDclgO
        y2E5LIflsByWw3JYDsthOSyH5YqHcjH2NbEclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyxUO5GPuW
        WA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYbnioVyMfU8sh+WwHJbDclgOy2E5LIflsByWw3JYDsth
        OSyH5bAclsNyWA7LYTksh+WwXPFQLsZ+JJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDcliueCgXYz8T
        y2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LFc8lItx3BLLYTksh+WwHJbDclgOy2E5LIflsByWw3JY
        DsthOSyH5bAclsNyWA7LYTksVzyUi3G0xHJYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDssVD+ViHD2x
        HJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDcsVDuRjHSCyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5
        LIflsByWw3JYDsthOSyH5bBc8VAuxrEklsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWK54KBfjWBPL
        YTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksVzyUi3FsieWwHJbDclgOy2E5LIflsByWw3JYDsthOSyH
        5bAclsNyWA7LYTksh+WwHJYrHsrFOPbEclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOyxUP5WIcR2I5
        LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIfliodyMY4zsRyWw3JYDsthOSyH5bAclsNyWA7LYTksh+Ww
        HJbDclgOy2E5LIflsByWw3LFQ7kY5y2xHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDcsVDuRhnSyyH
        5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bBc8VAuxtkTy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7L
        YTksh+WwHJbDclgOy2E5LFc8lItxjsRyWA7LYTksh+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LFQ/lYpxLYjks
        h+WwHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WKh3IxzjWxHJbDclgOy2E5LIflsByWw3JYDsthOSyH5bAc
        lsNyWA7LYTksh+WwHJbDcsVDuRjnllgOy2E5LIflsByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2G54qFcjHNPLIfl
        sByWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbDclgOy2E5LIflsFzxUC7GeSSWw3JYDsthOSyH5bAclsNyWA7LYTksh+WwHJbD
        clgOy2E5LIflsByWw3JYrngoF+M8E8thOSyH5bAclsNyWA7LYblyLPd/AA==
        """

    // 4732 bytes, CRC-32 0x50e56e54
    static let manySmallBlocks = """
        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
        zKfvoMwdxswETLbcHhoMHILcAA==
        """

}
