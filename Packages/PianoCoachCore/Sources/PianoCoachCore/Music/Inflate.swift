import Foundation

/// Error thrown when a DEFLATE stream is malformed or truncated.
public enum InflateError: Error, Equatable {
    case invalidData(String)
}

/// Pure-Swift decoder for raw DEFLATE streams (RFC 1951): stored, fixed-Huffman and
/// dynamic-Huffman blocks. No zlib/gzip header is expected (that is how ZIP stores data).
///
/// Huffman codes are decoded with a 10-bit lookup table; longer codes fall back to a
/// canonical (count/symbol) decode, so multi-megabyte inputs are handled quickly.
public enum Inflate {
    /// Decompresses a raw DEFLATE stream. Bytes after the final block are ignored.
    public static func inflate(_ data: Data) throws -> Data {
        try inflate(data, sizeHint: 0, limit: nil)
    }

    /// - Parameters:
    ///   - sizeHint: expected output size (used to pre-allocate; capped internally).
    ///   - limit: if set, decoding fails as soon as the output would exceed this many bytes.
    static func inflate(_ data: Data, sizeHint: Int, limit: Int?) throws -> Data {
        let initialCapacity = max(1024, min(sizeHint > 0 ? sizeHint : data.count * 4, 1 << 26))
        let output = InflateOutput(capacity: initialCapacity, limit: limit)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var decoder = InflateDecoder(input: bytes, output: output)
            try decoder.run()
        }
        return output.makeData()
    }
}

/// CRC-32 (IEEE 802.3, polynomial 0xEDB88320) as used by ZIP, gzip and PNG.
public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    /// CRC-32 of `data` (e.g. "123456789" -> 0xCBF43926).
    public static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { update(0, bytes: $0) }
    }

    /// Continues a running CRC-32 (`crc` is a previous result, 0 to start).
    static func update(_ crc: UInt32, bytes: UnsafeRawBufferPointer) -> UInt32 {
        var c = ~crc
        table.withUnsafeBufferPointer { t in
            for b in bytes {
                c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
            }
        }
        return ~c
    }
}

// MARK: - Output buffer

/// Growable byte buffer backed by manually managed memory (fast in debug builds too).
private final class InflateOutput {
    private(set) var pointer: UnsafeMutablePointer<UInt8>
    private(set) var capacity: Int
    var count = 0
    let limit: Int?

    init(capacity: Int, limit: Int?) {
        self.capacity = max(capacity, 16)
        self.pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: self.capacity)
        self.limit = limit
    }

    deinit {
        pointer.deallocate()
    }

    /// Makes room for `extra` more bytes.
    @inline(__always)
    func reserve(_ extra: Int) throws {
        let needed = count + extra
        if let limit = limit, needed > limit {
            throw InflateError.invalidData("output exceeds the expected size of \(limit) bytes")
        }
        if needed > capacity { grow(to: needed) }
    }

    private func grow(to needed: Int) {
        var newCapacity = capacity
        while newCapacity < needed { newCapacity = newCapacity &* 2 }
        if let limit = limit { newCapacity = max(needed, min(newCapacity, limit)) }
        let newPointer = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
        newPointer.initialize(from: pointer, count: count)
        pointer.deallocate()
        pointer = newPointer
        capacity = newCapacity
    }

    @inline(__always)
    func append(_ byte: UInt8) throws {
        if count >= capacity || limit != nil { try reserve(1) }
        pointer[count] = byte
        count += 1
    }

    func append(_ source: UnsafePointer<UInt8>, count n: Int) throws {
        guard n > 0 else { return }
        try reserve(n)
        (pointer + count).initialize(from: source, count: n)
        count += n
    }

    /// LZ77 back-reference: copies `length` bytes starting `distance` bytes back (may overlap).
    @inline(__always)
    func copyMatch(distance: Int, length: Int) throws {
        guard distance > 0, distance <= count else {
            throw InflateError.invalidData("back-reference distance \(distance) exceeds output size \(count)")
        }
        try reserve(length)
        let dst = pointer + count
        let src = dst - distance
        if distance >= length {
            dst.initialize(from: src, count: length)
        } else {
            for k in 0..<length { dst[k] = src[k] }
        }
        count += length
    }

    func makeData() -> Data {
        Data(bytes: pointer, count: count)
    }
}

// MARK: - Huffman tables

private struct HuffmanTable {
    static let fastBits = 10
    static let fastMask: UInt64 = (1 << UInt64(fastBits)) - 1

    /// Indexed by the next `fastBits` input bits (LSB first). Entry = (codeLength << 9) | symbol; 0 = not in table.
    var fast: [UInt16]
    /// Number of codes of each length 0...15.
    var counts: [Int]
    /// Symbols ordered by canonical code.
    var symbols: [UInt16]

    /// Builds a canonical Huffman table from per-symbol code lengths (0 = unused).
    /// Over-subscribed code sets are rejected; incomplete ones are allowed (unused codes fail on decode).
    init(lengths: ArraySlice<UInt8>) throws {
        var counts = [Int](repeating: 0, count: 16)
        for l in lengths { counts[Int(l)] += 1 }
        counts[0] = 0
        var left = 1
        for len in 1...15 {
            left <<= 1
            left -= counts[len]
            if left < 0 { throw InflateError.invalidData("over-subscribed Huffman code") }
        }

        var offsets = [Int](repeating: 0, count: 16)
        for len in 1..<15 { offsets[len + 1] = offsets[len] + counts[len] }
        var symbols = [UInt16](repeating: 0, count: lengths.count)
        var nextCode = [Int](repeating: 0, count: 16)
        var code = 0
        for bits in 1...15 {
            code = (code + counts[bits - 1]) << 1
            nextCode[bits] = code
        }

        var fast = [UInt16](repeating: 0, count: 1 << HuffmanTable.fastBits)
        for (i, l) in lengths.enumerated() where l != 0 {
            let len = Int(l)
            symbols[offsets[len]] = UInt16(i)
            offsets[len] += 1
            let c = nextCode[len]
            nextCode[len] += 1
            if len <= HuffmanTable.fastBits {
                // Codes are sent MSB first but read LSB first: index by the bit-reversed code.
                var reversed = 0
                for b in 0..<len where (c >> b) & 1 != 0 { reversed |= 1 << (len - 1 - b) }
                let entry = UInt16(len << 9 | i)
                var k = reversed
                while k < fast.count {
                    fast[k] = entry
                    k += 1 << len
                }
            }
        }
        self.fast = fast
        self.counts = counts
        self.symbols = symbols
    }

    init(lengths: [UInt8]) throws {
        try self.init(lengths: lengths[...])
    }

    static let fixedLiteral: HuffmanTable = {
        var lengths = [UInt8](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        // The fixed code is complete, so this cannot throw.
        return try! HuffmanTable(lengths: lengths)
    }()

    static let fixedDistance: HuffmanTable = {
        try! HuffmanTable(lengths: [UInt8](repeating: 5, count: 30))
    }()
}

// MARK: - Decoder

private struct InflateDecoder {
    let input: UnsafeBufferPointer<UInt8>
    let output: InflateOutput
    var position = 0
    var bitBuffer: UInt64 = 0
    var bitCount = 0

    static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                     3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                      257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                      8193, 12289, 16385, 24577]
    static let distanceExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                       7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    init(input: UnsafeBufferPointer<UInt8>, output: InflateOutput) {
        self.input = input
        self.output = output
    }

    mutating func run() throws {
        var isFinal = false
        repeat {
            isFinal = try bits(1) == 1
            switch try bits(2) {
            case 0: try storedBlock()
            case 1: try huffmanBlock(literal: HuffmanTable.fixedLiteral, distance: HuffmanTable.fixedDistance)
            case 2:
                let (literal, distance) = try dynamicTables()
                try huffmanBlock(literal: literal, distance: distance)
            default: throw InflateError.invalidData("invalid block type 3")
            }
        } while !isFinal
    }

    // MARK: Bits

    @inline(__always)
    mutating func refill() {
        while bitCount <= 56, position < input.count {
            bitBuffer |= UInt64(input[position]) << UInt64(bitCount)
            position += 1
            bitCount += 8
        }
    }

    /// Reads `n` (0...32) bits, LSB first.
    @inline(__always)
    mutating func bits(_ n: Int) throws -> Int {
        if bitCount < n {
            refill()
            if bitCount < n { throw InflateError.invalidData("unexpected end of data") }
        }
        let value = Int(bitBuffer & ((1 << UInt64(n)) - 1))
        bitBuffer >>= UInt64(n)
        bitCount -= n
        return value
    }

    @inline(__always)
    mutating func decodeSymbol(_ table: HuffmanTable) throws -> Int {
        if bitCount < 15 { refill() }
        let entry = table.fast[Int(bitBuffer & HuffmanTable.fastMask)]
        if entry != 0 {
            let len = Int(entry >> 9)
            if len > bitCount { throw InflateError.invalidData("unexpected end of data") }
            bitBuffer >>= UInt64(len)
            bitCount -= len
            return Int(entry & 0x1FF)
        }
        // Slow path: canonical decode one bit at a time (codes longer than `fastBits`).
        var code = 0, first = 0, index = 0
        for len in 1...15 {
            if len > bitCount { throw InflateError.invalidData("unexpected end of data") }
            code |= Int((bitBuffer >> UInt64(len - 1)) & 1)
            let count = table.counts[len]
            if code - first < count {
                bitBuffer >>= UInt64(len)
                bitCount -= len
                return Int(table.symbols[index + code - first])
            }
            index += count
            first = (first + count) << 1
            code <<= 1
        }
        throw InflateError.invalidData("invalid Huffman code")
    }

    // MARK: Blocks

    mutating func storedBlock() throws {
        // Drop the bits up to the byte boundary, then hand the whole bytes still buffered back to the input.
        _ = try bits(bitCount & 7)
        position -= bitCount / 8
        bitBuffer = 0
        bitCount = 0
        guard position + 4 <= input.count else { throw InflateError.invalidData("unexpected end of data") }
        let len = Int(input[position]) | Int(input[position + 1]) << 8
        let nlen = Int(input[position + 2]) | Int(input[position + 3]) << 8
        position += 4
        guard len == (~nlen & 0xFFFF) else { throw InflateError.invalidData("stored block length check failed") }
        guard position + len <= input.count else { throw InflateError.invalidData("unexpected end of data") }
        if len > 0, let base = input.baseAddress {
            try output.append(base + position, count: len)
        }
        position += len
    }

    mutating func huffmanBlock(literal: HuffmanTable, distance: HuffmanTable) throws {
        while true {
            let symbol = try decodeSymbol(literal)
            if symbol < 256 {
                try output.append(UInt8(truncatingIfNeeded: symbol))
            } else if symbol == 256 {
                return
            } else {
                let li = symbol - 257
                guard li < 29 else { throw InflateError.invalidData("invalid length symbol \(symbol)") }
                let length = InflateDecoder.lengthBase[li] + (try bits(InflateDecoder.lengthExtra[li]))
                let ds = try decodeSymbol(distance)
                guard ds < 30 else { throw InflateError.invalidData("invalid distance symbol \(ds)") }
                let dist = InflateDecoder.distanceBase[ds] + (try bits(InflateDecoder.distanceExtra[ds]))
                try output.copyMatch(distance: dist, length: length)
            }
        }
    }

    mutating func dynamicTables() throws -> (HuffmanTable, HuffmanTable) {
        let literalCount = try bits(5) + 257
        let distanceCount = try bits(5) + 1
        let codeLengthCount = try bits(4) + 4
        guard literalCount <= 286, distanceCount <= 30 else {
            throw InflateError.invalidData("too many length or distance codes")
        }
        var codeLengthLengths = [UInt8](repeating: 0, count: 19)
        for i in 0..<codeLengthCount {
            codeLengthLengths[InflateDecoder.codeLengthOrder[i]] = UInt8(try bits(3))
        }
        let codeLengthTable = try HuffmanTable(lengths: codeLengthLengths)

        let total = literalCount + distanceCount
        var lengths = [UInt8](repeating: 0, count: total)
        var i = 0
        while i < total {
            let symbol = try decodeSymbol(codeLengthTable)
            if symbol < 16 {
                lengths[i] = UInt8(symbol)
                i += 1
                continue
            }
            var value: UInt8 = 0
            let repeatCount: Int
            switch symbol {
            case 16:
                guard i > 0 else { throw InflateError.invalidData("repeat with no previous code length") }
                value = lengths[i - 1]
                repeatCount = 3 + (try bits(2))
            case 17:
                repeatCount = 3 + (try bits(3))
            case 18:
                repeatCount = 11 + (try bits(7))
            default:
                throw InflateError.invalidData("invalid code length symbol \(symbol)")
            }
            guard i + repeatCount <= total else { throw InflateError.invalidData("too many code lengths") }
            for k in i..<(i + repeatCount) { lengths[k] = value }
            i += repeatCount
        }
        guard lengths[256] != 0 else { throw InflateError.invalidData("missing end-of-block code") }
        let literal = try HuffmanTable(lengths: lengths[0..<literalCount])
        let distance = try HuffmanTable(lengths: lengths[literalCount..<total])
        return (literal, distance)
    }
}
