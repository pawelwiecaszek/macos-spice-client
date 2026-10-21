/// Errors raised while decoding untrusted wire data.
public enum WireError: Error, Equatable, Sendable {
    /// Tried to read past the end of the message.
    case truncated(needed: Int, available: Int)
    /// A pointer/offset field points outside the message.
    case badOffset(UInt32)
    /// A value is out of the range allowed by the protocol or by our limits.
    case invalidValue(String)
    /// A size exceeds a configured safety limit.
    case limitExceeded(String)
}

/// Little-endian reader over an immutable byte buffer.
///
/// SPICE structs are packed and little-endian. Never `memcpy` into Swift structs —
/// read field by field. All reads are bounds-checked and throw `WireError`.
public struct ByteReader: Sendable {
    /// The whole message. Pointer fields in SPICE messages are offsets from its start.
    public let buffer: [UInt8]
    public private(set) var offset: Int
    public let end: Int

    public init(_ buffer: [UInt8], offset: Int = 0) {
        self.buffer = buffer
        self.offset = offset
        self.end = buffer.count
    }

    public var remaining: Int { end - offset }
    public var isAtEnd: Bool { offset >= end }

    @inline(__always)
    private mutating func require(_ count: Int) throws(WireError) {
        guard count >= 0, count <= end - offset else {
            throw .truncated(needed: count, available: max(0, end - offset))
        }
    }

    public mutating func readU8() throws(WireError) -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return buffer[offset]
    }

    public mutating func readU16() throws(WireError) -> UInt16 {
        try require(2)
        defer { offset += 2 }
        return UInt16(buffer[offset]) | UInt16(buffer[offset + 1]) << 8
    }

    public mutating func readU32() throws(WireError) -> UInt32 {
        try require(4)
        defer { offset += 4 }
        return UInt32(buffer[offset])
            | UInt32(buffer[offset + 1]) << 8
            | UInt32(buffer[offset + 2]) << 16
            | UInt32(buffer[offset + 3]) << 24
    }

    public mutating func readU64() throws(WireError) -> UInt64 {
        let low = UInt64(try readU32())
        let high = UInt64(try readU32())
        return low | high << 32
    }

    public mutating func readI16() throws(WireError) -> Int16 { Int16(bitPattern: try readU16()) }
    public mutating func readI32() throws(WireError) -> Int32 { Int32(bitPattern: try readU32()) }
    public mutating func readI64() throws(WireError) -> Int64 { Int64(bitPattern: try readU64()) }

    /// Reads `count` raw bytes.
    public mutating func readBytes(_ count: Int) throws(WireError) -> ArraySlice<UInt8> {
        try require(count)
        defer { offset += count }
        return buffer[offset..<(offset + count)]
    }

    /// Reads everything that is left.
    public mutating func readRemaining() -> ArraySlice<UInt8> {
        defer { offset = end }
        return buffer[offset..<end]
    }

    public mutating func skip(_ count: Int) throws(WireError) {
        try require(count)
        offset += count
    }

    /// A reader positioned at `pointer` bytes from the start of the message.
    /// A zero pointer means "null" in SPICE and is rejected here — check before calling.
    public func reader(atPointer pointer: UInt32) throws(WireError) -> ByteReader {
        guard pointer != 0, Int(pointer) < end else { throw .badOffset(pointer) }
        return ByteReader(buffer, offset: Int(pointer))
    }
}
