// Main channel message bodies (spice.proto `channel MainChannel`).

/// `SPICE_MSG_MAIN_INIT`.
public struct MainInit: Sendable, Hashable {
    /// Used as `connection_id` when linking every other channel.
    public var sessionID: UInt32
    public var displayChannelsHint: UInt32
    public var supportedMouseModes: MouseModes
    public var currentMouseMode: MouseModes
    public var agentConnected: Bool
    public var agentTokens: UInt32
    public var multimediaTime: UInt32
    public var ramHint: UInt32

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        sessionID = try r.readU32()
        displayChannelsHint = try r.readU32()
        supportedMouseModes = MouseModes(rawValue: try r.readU32())
        currentMouseMode = MouseModes(rawValue: try r.readU32())
        agentConnected = try r.readU32() != 0
        agentTokens = try r.readU32()
        multimediaTime = try r.readU32()
        ramHint = try r.readU32()
    }
}

/// `SPICE_MSG_MAIN_CHANNELS_LIST`.
public struct ChannelsList: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public var rawType: UInt8
        public var id: UInt8
        public var type: ChannelType? { ChannelType(rawValue: rawType) }

        public init(rawType: UInt8, id: UInt8) {
            self.rawType = rawType
            self.id = id
        }
    }

    public var channels: [Entry]

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        let count = try r.readU32()
        guard Int(count) * 2 <= r.remaining else { throw .truncated(needed: Int(count) * 2, available: r.remaining) }
        channels = []
        for _ in 0..<count {
            channels.append(Entry(rawType: try r.readU8(), id: try r.readU8()))
        }
    }
}

/// `SPICE_MSG_MAIN_MOUSE_MODE` (fields are flags16 on the wire).
public struct MainMouseMode: Sendable, Hashable {
    public var supported: MouseModes
    public var current: MouseModes

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        supported = MouseModes(rawValue: UInt32(try r.readU16()))
        current = MouseModes(rawValue: UInt32(try r.readU16()))
    }
}

/// Single uint32 messages: `MULTI_MEDIA_TIME`, `AGENT_TOKEN`, `AGENT_CONNECTED_TOKENS`,
/// `AGENT_DISCONNECTED` (error code).
public struct MainUInt32: Sendable, Hashable {
    public var value: UInt32
    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        value = try r.readU32()
    }
}

/// `SPICE_MSG_MAIN_NAME`.
public struct MainName: Sendable, Hashable {
    public var name: String
    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        let length = try r.readU32()
        var text = try r.readBytes(Int(min(length, UInt32(r.remaining))))
        while text.last == 0 { text = text.dropLast() }
        name = String(decoding: text, as: UTF8.self)
    }
}

/// `SPICE_MSG_MAIN_UUID`.
public struct MainUUID: Sendable, Hashable {
    public var bytes: [UInt8]
    public init(decoding payload: [UInt8]) throws(WireError) {
        var r = ByteReader(payload)
        bytes = Array(try r.readBytes(16))
    }
}

/// Client → server main channel messages.
public enum MainClientEncoder {
    public static func attachChannels() -> SpiceMessage {
        SpiceMessage(type: MainClientMessage.attachChannels.rawValue, payload: [])
    }

    /// `SPICE_MSGC_MAIN_MOUSE_MODE_REQUEST` (flags16).
    public static func mouseModeRequest(_ mode: MouseModes) -> SpiceMessage {
        var w = ByteWriter()
        w.writeU16(UInt16(truncatingIfNeeded: mode.rawValue))
        return SpiceMessage(type: MainClientMessage.mouseModeRequest.rawValue, payload: w.bytes)
    }

    /// `SPICE_MSGC_MAIN_AGENT_START`: how many agent messages we can buffer.
    public static func agentStart(tokens: UInt32) -> SpiceMessage {
        var w = ByteWriter()
        w.writeU32(tokens)
        return SpiceMessage(type: MainClientMessage.agentStart.rawValue, payload: w.bytes)
    }

    /// `SPICE_MSGC_MAIN_AGENT_TOKEN`: return receive tokens to the server.
    public static func agentToken(_ tokens: UInt32) -> SpiceMessage {
        var w = ByteWriter()
        w.writeU32(tokens)
        return SpiceMessage(type: MainClientMessage.agentToken.rawValue, payload: w.bytes)
    }

    /// `SPICE_MSGC_MAIN_AGENT_DATA`: one agent chunk (≤ 2048 bytes, see vd_agent.h).
    public static func agentData(_ chunk: [UInt8]) -> SpiceMessage {
        SpiceMessage(type: MainClientMessage.agentData.rawValue, payload: chunk)
    }
}
