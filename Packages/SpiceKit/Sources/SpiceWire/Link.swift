/// A set of capability bits, transmitted as an array of little-endian uint32 words.
public struct CapabilitySet: Sendable, Hashable {
    public private(set) var words: [UInt32]

    public init(words: [UInt32] = []) { self.words = words }

    public init(bits: [Int]) {
        self.words = []
        for bit in bits { insert(bit) }
    }

    public mutating func insert(_ bit: Int) {
        let word = bit / 32
        while words.count <= word { words.append(0) }
        words[word] |= 1 << UInt32(bit % 32)
    }

    public func contains(_ bit: Int) -> Bool {
        let word = bit / 32
        guard word < words.count else { return false }
        return words[word] & (1 << UInt32(bit % 32)) != 0
    }
}

/// `SpiceLinkHeader` + `SpiceLinkMess` (protocol.h), sent by the client to open a channel.
public struct LinkMessage: Sendable, Equatable {
    public var connectionID: UInt32
    public var channelType: ChannelType
    public var channelID: UInt8
    public var commonCaps: CapabilitySet
    public var channelCaps: CapabilitySet

    public init(connectionID: UInt32, channelType: ChannelType, channelID: UInt8,
                commonCaps: CapabilitySet, channelCaps: CapabilitySet) {
        self.connectionID = connectionID
        self.channelType = channelType
        self.channelID = channelID
        self.commonCaps = commonCaps
        self.channelCaps = channelCaps
    }

    /// `sizeof(SpiceLinkMess)`: u32 + u8 + u8 + u32 + u32 + u32.
    static let fixedSize = 18

    /// Encodes header + body.
    public func encode() -> [UInt8] {
        let capsSize = 4 * (commonCaps.words.count + channelCaps.words.count)
        var writer = ByteWriter(capacity: 16 + Self.fixedSize + capsSize)
        // SpiceLinkHeader
        writer.writeU32(spiceMagic)
        writer.writeU32(spiceVersionMajor)
        writer.writeU32(spiceVersionMinor)
        writer.writeU32(UInt32(Self.fixedSize + capsSize))
        // SpiceLinkMess
        writer.writeU32(connectionID)
        writer.writeU8(channelType.rawValue)
        writer.writeU8(channelID)
        writer.writeU32(UInt32(commonCaps.words.count))
        writer.writeU32(UInt32(channelCaps.words.count))
        writer.writeU32(UInt32(Self.fixedSize))  // caps_offset, relative to SpiceLinkMess
        for word in commonCaps.words { writer.writeU32(word) }
        for word in channelCaps.words { writer.writeU32(word) }
        return writer.bytes
    }
}

/// `SpiceLinkHeader` as received from the server.
public struct LinkHeader: Sendable, Equatable {
    public static let size = 16
    public var magic: UInt32
    public var major: UInt32
    public var minor: UInt32
    public var bodySize: UInt32

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var reader = ByteReader(bytes)
        magic = try reader.readU32()
        major = try reader.readU32()
        minor = try reader.readU32()
        bodySize = try reader.readU32()
    }
}

/// `SpiceLinkReply` (protocol.h).
public struct LinkReply: Sendable, Equatable {
    /// Raw `SpiceLinkErr`; use `linkError` for the typed value.
    public var errorCode: UInt32
    /// RSA-1024 public key, X.509 SubjectPublicKeyInfo DER (162 bytes).
    public var publicKey: [UInt8]
    public var commonCaps: CapabilitySet
    public var channelCaps: CapabilitySet

    public var linkError: LinkError? { LinkError(rawValue: errorCode) }

    /// Caps arrays beyond this many words are rejected as hostile.
    static let maxCapWords: UInt32 = 1024

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var reader = ByteReader(bytes)
        errorCode = try reader.readU32()
        publicKey = Array(try reader.readBytes(spiceTicketPublicKeyBytes))
        let numCommon = try reader.readU32()
        let numChannel = try reader.readU32()
        let capsOffset = try reader.readU32()
        guard numCommon <= Self.maxCapWords, numChannel <= Self.maxCapWords else {
            throw .limitExceeded("link reply caps")
        }
        var caps = ByteReader(bytes, offset: 0)
        try caps.skip(Int(capsOffset))
        var common: [UInt32] = []
        for _ in 0..<numCommon { common.append(try caps.readU32()) }
        var channel: [UInt32] = []
        for _ in 0..<numChannel { channel.append(try caps.readU32()) }
        commonCaps = CapabilitySet(words: common)
        channelCaps = CapabilitySet(words: channel)
    }
}

/// `SpiceMiniDataHeader`: 6 bytes, used once `SPICE_COMMON_CAP_MINI_HEADER` is negotiated.
public struct MiniHeader: Sendable, Equatable {
    public static let size = 6
    public var type: UInt16
    public var size: UInt32

    public init(type: UInt16, size: UInt32) {
        self.type = type
        self.size = size
    }

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var reader = ByteReader(bytes)
        type = try reader.readU16()
        size = try reader.readU32()
    }

    public func encode() -> [UInt8] {
        var writer = ByteWriter(capacity: Self.size)
        writer.writeU16(type)
        writer.writeU32(size)
        return writer.bytes
    }
}

/// A complete message on an established channel.
public struct SpiceMessage: Sendable, Equatable {
    public var type: UInt16
    public var payload: [UInt8]

    public init(type: UInt16, payload: [UInt8]) {
        self.type = type
        self.payload = payload
    }

    /// Header + payload, ready to send.
    public func encode() -> [UInt8] {
        var bytes = MiniHeader(type: type, size: UInt32(payload.count)).encode()
        bytes.append(contentsOf: payload)
        return bytes
    }
}
