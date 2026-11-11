import Foundation
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
    private let synchronization: ChannelSynchronization
    private let token = UUID()
    private var registered = false
    private var closed = false
    private var reading = false
    private var receivedSerial: UInt64 = 0
    private var deliveredSerial: UInt64?
    private(set) var lastHandledSerial: UInt64 = 0
    private var key: ChannelSynchronization.Key { .init(type: type, id: id) }

    private var ackWindow: UInt32 = 0
    private var messagesSinceAck: UInt32 = 0

    /// Largest message accepted from the server (hostile-input bound).
    public static let maxMessageSize: UInt32 = 128 * 1024 * 1024

    public init(type: ChannelType, id: UInt8, stream: any SpiceByteStream, serverCaps: CapabilitySet,
                synchronization: ChannelSynchronization? = nil) {
        self.type = type
        self.id = id
        self.stream = stream
        self.serverCaps = serverCaps
        self.synchronization = synchronization ?? ChannelSynchronization()
        self.log = ChannelLogger(category: "\(type)")
    }

    public func send(_ message: SpiceMessage) async throws {
        try await stream.send(message.encode())
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        await synchronization.close(key, token: token)
        await stream.close()
    }

    /// Registers this authenticated channel with its session before it can receive data.
    func prepare() async throws {
        guard !closed else { throw ChannelSynchronization.Failure.channelClosed }
        if !registered {
            try await synchronization.register(key, token: token)
            registered = true
        }
        guard !closed else {
            await synchronization.close(key, token: token)
            throw ChannelSynchronization.Failure.channelClosed
        }
    }

    /// Publish completion only after the previously returned message's handler has
    /// finished. Consumers call this at the top of their next receive-loop iteration,
    /// so recoverable-error/continue paths complete but fatal handler exits do not.
    public func messageHandled() async {
        guard !closed, let serial = deliveredSerial else { return }
        deliveredSerial = nil
        lastHandledSerial = serial
        await synchronization.complete(key, token: token, serial: serial)
    }

    /// Honor an embedded display barrier while the current message is being handled.
    public func waitForChannels(_ wait: WaitForChannels) async throws {
        guard !closed, let serial = deliveredSerial else { throw ChannelError.malformed("wait outside message handler") }
        try await synchronization.wait(wait.entries, owner: key, token: token, currentSerial: serial)
    }

    /// Next channel-specific message. The previous delivery must be acknowledged with
    /// messageHandled() before another read. Base messages count and complete internally.
    public func nextMessage() async throws -> SpiceMessage {
        guard !reading, deliveredSerial == nil else { throw ChannelError.malformed("overlapping channel receive") }
        reading = true
        defer { reading = false }
        do {
            try await prepare()
            while true {
                try Task.checkCancellation()
                let message = try await receiveRaw()
                // spice-gtk@f04479c spice-channel.c:456–465,2162–2170:
                // MINI_HEADER has an implicit serial, first=1; every outer message counts.
                guard receivedSerial < UInt64.max else { throw ChannelError.malformed("channel serial overflow") }
                receivedSerial += 1
                let serial = receivedSerial
                if try await handleBase(message, serial: serial) {
                    lastHandledSerial = serial
                    await synchronization.complete(key, token: token, serial: serial)
                    continue
                }
                deliveredSerial = serial
                return message
            }
        } catch {
            await close()
            throw error
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
    private func handleBase(_ message: SpiceMessage, serial: UInt64) async throws -> Bool {
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
            let wait = try WaitForChannels(decoding: message.payload)
            try await synchronization.wait(wait.entries, owner: key, token: token, currentSerial: serial)
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
