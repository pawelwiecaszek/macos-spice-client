// Messages shared by every channel (spice.proto `channel BaseChannel`).

/// `SPICE_MSG_SET_ACK`.
public struct SetAck: Sendable, Hashable {
    public var generation: UInt32
    public var window: UInt32

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        generation = try r.readU32()
        window = try r.readU32()
    }
}

/// `SPICE_MSG_PING`. The trailing data only measures bandwidth and is ignored.
public struct Ping: Sendable, Hashable {
    public var id: UInt32
    public var timestamp: UInt64

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        id = try r.readU32()
        timestamp = try r.readU64()
    }
}

/// `SPICE_MSG_NOTIFY`.
public struct Notify: Sendable, Hashable {
    public var timestamp: UInt64
    public var severity: UInt32
    public var visibility: UInt32
    public var what: UInt32
    public var message: String

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        timestamp = try r.readU64()
        severity = try r.readU32()
        visibility = try r.readU32()
        what = try r.readU32()
        let length = try r.readU32()
        var text = try r.readBytes(Int(min(length, UInt32(r.remaining))))
        if text.last == 0 { text = text.dropLast() }
        message = String(decoding: text, as: UTF8.self)
    }
}

/// `SPICE_MSG_DISCONNECTING`.
public struct Disconnecting: Sendable, Hashable {
    public var timestamp: UInt64
    public var reason: UInt32

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        timestamp = try r.readU64()
        reason = try r.readU32()
    }
}

/// `SpiceWaitForChannel` list used by `WAIT_FOR_CHANNELS` and `INVAL_ALL_PIXMAPS`.
public struct WaitForChannels: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public var channelType: UInt8
        public var channelID: UInt8
        public var messageSerial: UInt64
    }

    public var entries: [Entry]

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        let count = try r.readU8()
        entries = []
        for _ in 0..<count {
            entries.append(Entry(channelType: try r.readU8(), channelID: try r.readU8(), messageSerial: try r.readU64()))
        }
    }
}

/// Client → server base messages.
public enum BaseClientEncoder {
    public static func ackSync(generation: UInt32) -> SpiceMessage {
        var w = ByteWriter()
        w.writeU32(generation)
        return SpiceMessage(type: BaseClientMessage.ackSync.rawValue, payload: w.bytes)
    }

    public static func ack() -> SpiceMessage {
        SpiceMessage(type: BaseClientMessage.ack.rawValue, payload: [])
    }

    public static func pong(id: UInt32, timestamp: UInt64) -> SpiceMessage {
        var w = ByteWriter()
        w.writeU32(id)
        w.writeU64(timestamp)
        return SpiceMessage(type: BaseClientMessage.pong.rawValue, payload: w.bytes)
    }
}
