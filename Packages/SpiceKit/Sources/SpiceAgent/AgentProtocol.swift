import SpiceWire

// spice-vdagent protocol, carried in main-channel AGENT_DATA messages.
// Constants transcribed from spice-protocol 0.14.3 spice/vd_agent.h (BSD-licensed).

/// `VD_AGENT_PROTOCOL`.
public let vdAgentProtocol: UInt32 = 1
/// `VD_AGENT_MAX_DATA_SIZE`: largest AGENT_DATA payload (header included).
public let vdAgentMaxDataSize = 2048

/// `VD_AGENT_*` message types.
public enum AgentMessageType: UInt32, Sendable {
    case mouseState = 1
    case monitorsConfig
    case reply
    case clipboard
    case displayConfig
    case announceCapabilities
    case clipboardGrab
    case clipboardRequest
    case clipboardRelease
    case fileXferStart
    case fileXferStatus
    case fileXferData
    case clientDisconnected
    case maxClipboard
    case audioVolumeSync
    case graphicsDeviceInfo
}

/// `VD_AGENT_CAP_*` bit indices.
public enum AgentCapability: Int, Sendable, CaseIterable {
    case mouseState = 0
    case monitorsConfig
    case reply
    case clipboard
    case displayConfig
    case clipboardByDemand
    case clipboardSelection
    case sparseMonitorsConfig
    case guestLineEndLF
    case guestLineEndCRLF
    case maxClipboard
    case audioVolumeSync
    case monitorsConfigPosition
    case fileXferDisabled
    case fileXferDetailedErrors
    case graphicsDeviceInfo
    case clipboardNoReleaseOnRegrab
    case clipboardGrabSerial
}

/// A complete agent message (`VDAgentMessage` header + data).
public struct AgentMessage: Sendable, Equatable {
    public static let headerSize = 20

    public var type: UInt32
    public var opaque: UInt64
    public var data: [UInt8]

    public init(type: AgentMessageType, opaque: UInt64 = 0, data: [UInt8]) {
        self.type = type.rawValue
        self.opaque = opaque
        self.data = data
    }

    public init(rawType: UInt32, opaque: UInt64, data: [UInt8]) {
        self.type = rawType
        self.opaque = opaque
        self.data = data
    }

    public var knownType: AgentMessageType? { AgentMessageType(rawValue: type) }

    /// Header + data, split into AGENT_DATA payloads of at most `vdAgentMaxDataSize`.
    public func encodeChunks() -> [[UInt8]] {
        var writer = ByteWriter(capacity: Self.headerSize + data.count)
        writer.writeU32(vdAgentProtocol)
        writer.writeU32(type)
        writer.writeU64(opaque)
        writer.writeU32(UInt32(data.count))
        writer.writeBytes(data)
        let bytes = writer.bytes
        return stride(from: 0, to: bytes.count, by: vdAgentMaxDataSize).map {
            Array(bytes[$0..<min($0 + vdAgentMaxDataSize, bytes.count)])
        }
    }

    /// `VD_AGENT_ANNOUNCE_CAPABILITIES`.
    public static func announceCapabilities(request: Bool, capabilities: [AgentCapability]) -> AgentMessage {
        let caps = CapabilitySet(bits: capabilities.map(\.rawValue))
        var writer = ByteWriter()
        writer.writeU32(request ? 1 : 0)
        for word in caps.words { writer.writeU32(word) }
        return AgentMessage(type: .announceCapabilities, data: writer.bytes)
    }

    /// `VD_AGENT_MONITORS_CONFIG` for a set of monitors (sizes in guest pixels).
    public static func monitorsConfig(_ monitors: [(width: UInt32, height: UInt32, x: Int32, y: Int32)],
                                      usePosition: Bool = true) -> AgentMessage {
        var writer = ByteWriter()
        writer.writeU32(UInt32(monitors.count))
        writer.writeU32(usePosition ? 1 : 0)  // VD_AGENT_CONFIG_MONITORS_FLAG_USE_POS
        for monitor in monitors {
            writer.writeU32(monitor.height)
            writer.writeU32(monitor.width)
            writer.writeU32(32)  // depth
            writer.writeI32(monitor.x)
            writer.writeI32(monitor.y)
        }
        return AgentMessage(type: .monitorsConfig, data: writer.bytes)
    }
}

/// Reassembles agent messages that the server split across AGENT_DATA messages.
public struct AgentMessageAssembler: Sendable {
    /// Refuse absurd sizes from a hostile agent.
    public var maxMessageSize = 64 * 1024 * 1024
    private var pending: [UInt8] = []

    public init() {}

    /// Feeds one AGENT_DATA payload; returns any messages completed by it.
    public mutating func feed(_ chunk: [UInt8]) throws(WireError) -> [AgentMessage] {
        pending.append(contentsOf: chunk)
        var messages: [AgentMessage] = []
        while pending.count >= AgentMessage.headerSize {
            var reader = ByteReader(pending)
            let proto = try reader.readU32()
            let type = try reader.readU32()
            let opaque = try reader.readU64()
            let size = Int(try reader.readU32())
            guard proto == vdAgentProtocol else {
                pending.removeAll()
                throw .invalidValue("agent protocol \(proto)")
            }
            guard size <= maxMessageSize else {
                pending.removeAll()
                throw .limitExceeded("agent message \(size)")
            }
            guard pending.count >= AgentMessage.headerSize + size else { break }
            let data = Array(pending[AgentMessage.headerSize..<(AgentMessage.headerSize + size)])
            pending.removeFirst(AgentMessage.headerSize + size)
            messages.append(AgentMessage(rawType: type, opaque: opaque, data: data))
        }
        return messages
    }
}
