/// Little-endian writer producing a byte buffer.
public struct ByteWriter: Sendable {
    public private(set) var bytes: [UInt8]

    public init(capacity: Int = 64) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    public var count: Int { bytes.count }

    public mutating func writeU8(_ value: UInt8) { bytes.append(value) }

    public mutating func writeU16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    public mutating func writeU32(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    public mutating func writeU64(_ value: UInt64) {
        writeU32(UInt32(truncatingIfNeeded: value))
        writeU32(UInt32(truncatingIfNeeded: value >> 32))
    }

    public mutating func writeI16(_ value: Int16) { writeU16(UInt16(bitPattern: value)) }
    public mutating func writeI32(_ value: Int32) { writeU32(UInt32(bitPattern: value)) }
    public mutating func writeI64(_ value: Int64) { writeU64(UInt64(bitPattern: value)) }

    public mutating func writeBytes<C: Collection>(_ data: C) where C.Element == UInt8 {
        bytes.append(contentsOf: data)
    }
}
