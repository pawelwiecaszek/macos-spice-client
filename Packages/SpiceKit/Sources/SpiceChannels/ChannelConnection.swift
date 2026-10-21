import SpiceTransport
import SpiceWire

/// Why a channel stopped.
public enum ChannelError: Error, Equatable, Sendable {
    case serverDisconnected(reason: UInt32)
    case migrationUnsupported
    case messageTooLarge(UInt32)
    case malformed(String)
}

/// One established SPICE channel: mini-header framing plus the base protocol
/// (`SET_ACK`/`ACK`, `PING`/`PONG`, `NOTIFY`, `DISCONNECTING`, `MIGRATE*`).
///
/// `nextMessage()` handles base messages internally and returns only channel-specific ones.
public actor ChannelConnection {
    public nonisolated let type: ChannelType
    public nonisolated let id: UInt8
    public let serverCaps: CapabilitySet
    private let stream: any SpiceByteStream
    private let log: ChannelLogger

    private var ackWindow: UInt32 = 0
    private var messagesSinceAck: UInt32 = 0

    /// Largest message accepted from the server (hostile-input bound).
    public static let maxMessageSize: UInt32 = 128 * 1024 * 1024

    public init(type: ChannelType, id: UInt8, stream: any SpiceByteStream, serverCaps: CapabilitySet) {
        self.type = type
        self.id = id
        self.stream = stream
        self.serverCaps = serverCaps
        self.log = ChannelLogger(category: "\(type)")
    }

    public func send(_ message: SpiceMessage) async throws {
        try await stream.send(message.encode())
    }

    public func close() async {
        await stream.close()
    }

    /// Next channel-specific message (type ≥ 101).
    public func nextMessage() async throws -> SpiceMessage {
        while true {
            let message = try await receiveRaw()
            if try await handleBase(message) { continue }
            return message
        }
    }

    private func receiveRaw() async throws -> SpiceMessage {
        let header = try MiniHeader(decoding: try await stream.receive(exactly: MiniHeader.size))
        guard header.size <= Self.maxMessageSize else { throw ChannelError.messageTooLarge(header.size) }
        let payload = header.size > 0 ? try await stream.receive(exactly: Int(header.size)) : []
        if ackWindow > 0 {
            messagesSinceAck += 1
            if messagesSinceAck >= ackWindow {
                messagesSinceAck = 0
                try await send(BaseClientEncoder.ack())
            }
        }
        return SpiceMessage(type: header.type, payload: payload)
    }

    /// Returns `true` if the message was a base-channel message and has been handled.
    private func handleBase(_ message: SpiceMessage) async throws -> Bool {
        guard message.type < 101, let base = BaseServerMessage(rawValue: message.type) else {
            return message.type < 101  // unknown base message: ignore
        }
        switch base {
        case .setAck:
            let ack = try SetAck(decoding: message.payload)
            ackWindow = ack.window
            messagesSinceAck = 0
            try await send(BaseClientEncoder.ackSync(generation: ack.generation))
        case .ping:
            let ping = try Ping(decoding: message.payload)
            try await send(BaseClientEncoder.pong(id: ping.id, timestamp: ping.timestamp))
        case .notify:
            if let notify = try? Notify(decoding: message.payload) {
                // Server text is untrusted and may identify hosts: private, sanitized.
                log.sensitive("server notify severity=\(notify.severity):", ChannelLogger.sanitize(notify.message))
            }
        case .disconnecting:
            let info = try Disconnecting(decoding: message.payload)
            throw ChannelError.serverDisconnected(reason: info.reason)
        case .waitForChannels:
            // Ordering across channels is not enforced in v1; each channel is processed in order.
            log.debug("wait_for_channels ignored")
        case .migrate, .migrateData:
            log.info("migration requested; not supported in v1")
            throw ChannelError.migrationUnsupported
        case .list:
            // Sub-message lists are only used with the full (non-mini) header.
            log.debug("ignoring SPICE_MSG_LIST")
        }
        return true
    }
}
