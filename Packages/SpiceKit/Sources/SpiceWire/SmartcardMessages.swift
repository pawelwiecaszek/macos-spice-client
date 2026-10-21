// Smartcard channel (spice.proto `channel SmartcardChannel`).
//
// Both directions carry one virtual-smartcard (VSC) message per SPICE message, type 101
// (`SPICE_MSG_SMARTCARD_DATA` / `SPICE_MSGC_SMARTCARD_DATA`): a 12-byte header
// `type`, `reader_id`, `length` (uint32 each) followed by `length` bytes.
//
// Byte order: on the SPICE wire the header is little-endian like every other SPICE field
// (spice-server converts to network order only towards QEMU's ccid-card-passthru).
// Verified against QEMU 8.2 / spice-server 0.15: a big-endian header makes the server
// drop the channel; little-endian `READER_ADD` is answered with `ERROR(success)`.

/// VSC message types (protocol version 2).
public enum VSCMessageType: UInt32, Sendable {
    case initialize = 1
    case error = 2
    case readerAdd = 3
    case readerRemove = 4
    case atr = 5
    case cardRemove = 6
    case apdu = 7
    case flush = 8
    case flushComplete = 9
}

/// Codes carried by `VSC_Error`. `success` doubles as the acknowledgement of
/// `READER_ADD` (its `readerID` is the id the server assigned).
public enum VSCErrorCode: UInt32, Sendable {
    case success = 0
    case generalError = 1
    case cannotAddMoreReaders = 2
    case cardAlreadyInserted = 3
}

/// One VSC message.
public struct VSCMessage: Sendable, Equatable {
    /// `READER_ADD` is sent with this id; the server answers with the real one.
    public static let undefinedReaderID: UInt32 = 0xFFFF_FFFF
    /// Largest payload accepted from the server (extended APDUs are < 64 KiB).
    public static let maxPayload = 128 * 1024
    static let headerSize = 12
    static let channelMessageType: UInt16 = 101

    public var rawType: UInt32
    public var readerID: UInt32
    public var data: [UInt8]

    public var type: VSCMessageType? { VSCMessageType(rawValue: rawType) }

    public init(_ type: VSCMessageType, readerID: UInt32, data: [UInt8] = []) {
        self.rawType = type.rawValue
        self.readerID = readerID
        self.data = data
    }

    public init(decoding payload: [UInt8]) throws(WireError) {
        var r = ByteReader(payload)
        rawType = try r.readU32()
        readerID = try r.readU32()
        let length = Int(try r.readU32())
        guard length <= Self.maxPayload else { throw .limitExceeded("smartcard payload \(length)") }
        guard length <= r.remaining else { throw .truncated(needed: length, available: r.remaining) }
        data = Array(payload[Self.headerSize ..< Self.headerSize + length])
    }

    /// `VSC_Error` code, if this is an error message.
    public var errorCode: UInt32? {
        guard type == .error, data.count >= 4 else { return nil }
        var r = ByteReader(data)
        return try? r.readU32()
    }

    public static func error(_ code: VSCErrorCode, readerID: UInt32) -> VSCMessage {
        var w = ByteWriter()
        w.writeU32(code.rawValue)
        return VSCMessage(.error, readerID: readerID, data: w.bytes)
    }

    /// Client → server SPICE message.
    public func encode() -> SpiceMessage {
        var w = ByteWriter(capacity: Self.headerSize + data.count)
        w.writeU32(rawType)
        w.writeU32(readerID)
        w.writeU32(UInt32(data.count))
        w.writeBytes(data)
        return SpiceMessage(type: Self.channelMessageType, payload: w.bytes)
    }

    /// `true` for the SPICE message type that carries VSC data.
    public static func isData(_ message: SpiceMessage) -> Bool { message.type == channelMessageType }
}
