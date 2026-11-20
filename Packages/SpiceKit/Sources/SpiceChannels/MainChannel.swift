import Foundation
import SpiceAgent
import SpiceWire

/// Events from the main channel.
public enum MainEvent: Sendable, Equatable {
    case monitorResizeAuthorization(MonitorResizeAuthorization)
    case initialized(sessionID: UInt32, mouseModes: MouseModes, currentMode: MouseModes, agentConnected: Bool)
    case channels([ChannelsList.Entry])
    case mouseMode(current: MouseModes, supported: MouseModes)
    case agentConnected(Bool)
    case guestName(String)
    case guestUUID([UInt8])
    case agentMessage(AgentMessage)
    /// Capabilities the guest agent announced.
    case agentCapabilities(CapabilitySet)
}

/// Main channel: session setup, channel list, mouse mode and the vdagent pipe.
public actor MainChannel {
    /// Channel caps the client advertises.
    public static let capabilities = CapabilitySet(bits: [
        MainCapability.nameAndUUID.rawValue,
        MainCapability.agentConnectedTokens.rawValue,
    ])

    /// vdagent capabilities this client announces.
    public static let agentCapabilities: [AgentCapability] = [
        .mouseState, .monitorsConfig, .reply, .sparseMonitorsConfig, .monitorsConfigPosition,
        .clipboardByDemand, .clipboardSelection,
    ]

    /// Agent messages we can buffer (returned to the server as we consume them).
    static let agentReceiveTokens: UInt32 = 10

    private let connection: ChannelConnection
    private let events: AsyncStream<MainEvent>.Continuation
    private let log = ChannelLogger(category: "main")

    private var supportedModes: MouseModes = []
    private var currentMode: MouseModes = []
    private var agentConnected = false
    private var peerAgentCaps = CapabilitySet()
    private struct PendingMonitorLayout {
        let layout: GuestMonitorLayout
        let authorizations: [MonitorResizeAuthorization]
        var isCurrent: Bool { authorizations.allSatisfy(\.isCurrent) }
    }
    private var pendingMonitorLayout: PendingMonitorLayout?
    private var flushingAgentOutbox = false
    private let monitorResizeAuthority = MonitorResizeAuthority()
    private var agentFileEpoch = UUID()
    private var fileMessages: [QueuedAgentFileMessage] = []
    private var fileMessageBytes = 0
    private var activeFileEpoch: UUID?
    private var fileFlushTask: Task<Void, Never>?
    /// Messages we may still send to the agent.
    private var agentSendTokens: UInt32 = 0
    private var agentOutbox: [[UInt8]] = []
    private var agentOutboxBytes = 0
    /// Bytes queued for the agent but not yet sent (used to pace bulk transfers).
    public var pendingAgentBytes: Int { agentOutboxBytes + fileMessageBytes }
    public var isAgentConnected: Bool { agentConnected }
    /// A capability reply is waiting for tokens: further requests are coalesced into it.
    private var capabilityReplyQueued = false
    /// Room for one maximal clipboard transfer plus control traffic; beyond that the agent
    /// (which controls our send tokens) is not draining and new messages are dropped.
    static let maxAgentOutboxBytes = ClipboardCodec.maxDataSize + 1024 * 1024
    private var agentAssembler = AgentMessageAssembler()
    private var consumedAgentMessages: UInt32 = 0

    private let clock: MultimediaClock?

    public init(connection: ChannelConnection, events: AsyncStream<MainEvent>.Continuation,
                clock: MultimediaClock? = nil) {
        self.clock = clock
        self.connection = connection
        self.events = events
    }

    /// Processes messages until the channel closes (throws on error or disconnect).
    public func run() async throws {
        defer {
            retireAgentFiles()
            fileFlushTask?.cancel()
            monitorResizeAuthority.invalidate()
            pendingMonitorLayout = nil
            peerAgentCaps = CapabilitySet()
            agentConnected = false
            events.finish()
        }
        while true {
            await connection.messageHandled()
            let message = try await connection.nextMessage()
            try await handle(message)
        }
    }

    public func close() async {
        retireAgentFiles()
        fileFlushTask?.cancel()
        monitorResizeAuthority.invalidate()
        pendingMonitorLayout = nil
        peerAgentCaps = CapabilitySet()
        agentConnected = false
        await connection.close()
    }

    /// Accepts one complete desired monitor set, gated by the current agent's
    /// capabilities. Token-starved requests coalesce before encoding begins.
    @discardableResult
    public func requestMonitorLayout(_ layout: GuestMonitorLayout,
                                     authorizations: [MonitorResizeAuthorization] = []) async throws -> Bool {
        guard authorizations.count <= 6, authorizations.allSatisfy(\.isCurrent),
              agentConnected, layout.message(capabilities: peerAgentCaps) != nil else { return false }
        pendingMonitorLayout = PendingMonitorLayout(layout: layout, authorizations: authorizations)
        try await flushAgentOutbox()
        return true
    }

    public var fileTransferAuthorization: AgentFileTransferAuthorization? {
        agentConnected ? AgentFileTransferAuthorization(epoch: agentFileEpoch) : nil
    }

    /// Performs no socket I/O on the caller's task. One owned sender prevents
    /// cancellation of a file task from cancelling the shared connection.
    public func enqueueFileTransfer(_ message: AgentMessage, authorization: AgentFileTransferAuthorization) throws {
        try queueFileMessage(message, authorization: authorization, cleanup: false)
    }

    public func cancelFileTransfer(id: UInt32, authorization: AgentFileTransferAuthorization) throws {
        guard agentConnected, authorization.epoch == agentFileEpoch else { throw AgentFileTransferAdmissionError.unavailable }
        fileMessages.removeAll { item in
            if item.id == id { fileMessageBytes -= item.byteCount; return true }
            return false
        }
        try queueFileMessage(FileTransferCodec.status(id: id, result: .cancelled), authorization: authorization, cleanup: true)
    }

    private func queueFileMessage(_ message: AgentMessage, authorization: AgentFileTransferAuthorization, cleanup: Bool) throws {
        guard agentConnected, authorization.epoch == agentFileEpoch else { throw AgentFileTransferAdmissionError.unavailable }
        guard cleanup || !peerAgentCaps.contains(AgentCapability.fileXferDisabled.rawValue) else {
            throw AgentFileTransferAdmissionError.disabledByGuest
        }
        guard [.fileXferStart, .fileXferData, .fileXferStatus].contains(message.knownType),
              message.data.count >= 4, message.data.count <= 64 * 1024 else { throw AgentFileTransferAdmissionError.invalidMessage }
        var reader = ByteReader(message.data)
        let id = try reader.readU32()
        let entry = QueuedAgentFileMessage(id: id, epoch: authorization.epoch, chunks: message.encodeChunks(), cleanup: cleanup)
        let limit = Self.maxAgentOutboxBytes - (cleanup ? 0 : 64 * 1024)
        guard fileMessages.count < (cleanup ? 80 : 64), pendingAgentBytes + entry.byteCount <= limit else {
            throw AgentFileTransferAdmissionError.queueFull
        }
        fileMessages.append(entry)
        fileMessageBytes += entry.byteCount
        guard fileFlushTask == nil else { return }
        fileFlushTask = Task { [weak self] in
            guard let self else { return }
            await self.flushFileMessages()
        }
    }

    private func flushFileMessages() async {
        defer { fileFlushTask = nil }
        do { try await flushAgentOutbox() }
        catch { await connection.close() }
    }

    private func retireAgentFiles() {
        agentFileEpoch = UUID()
        fileMessages.removeAll()
        fileMessageBytes = 0
        activeFileEpoch = nil
    }

    /// Requests client (absolute) or server (relative) mouse mode.
    public func requestMouseMode(_ mode: MouseModes) async throws {
        guard supportedModes.contains(mode), mode != currentMode else { return }
        try await connection.send(MainClientEncoder.mouseModeRequest(mode))
    }

    /// Sends a message to the guest agent, respecting token flow control.
    ///
    /// Messages that don't fit the bounded outbox are dropped (logged), never queued
    /// without limit while the agent withholds tokens.
    public func sendToAgent(_ message: AgentMessage) async throws {
        guard agentConnected else { return }
        let chunks = message.encodeChunks()
        let size = chunks.reduce(0) { $0 + $1.count }
        guard pendingAgentBytes + size <= Self.maxAgentOutboxBytes else {
            log.info("agent outbox full; dropping a type \(message.type) message")
            return
        }
        agentOutbox.append(contentsOf: chunks)
        agentOutboxBytes += size
        try await flushAgentOutbox()
    }

    private func flushAgentOutbox() async throws {
        guard !flushingAgentOutbox else { return }
        flushingAgentOutbox = true
        defer { flushingAgentOutbox = false }
        while agentConnected, agentSendTokens > 0 {
            if agentOutbox.isEmpty, let request = pendingMonitorLayout {
                pendingMonitorLayout = nil
                if request.isCurrent, let message = request.layout.message(capabilities: peerAgentCaps) {
                    let chunks = message.encodeChunks()
                    agentOutbox = chunks
                    agentOutboxBytes = chunks.reduce(0) { $0 + $1.count }
                }
            }
            if agentOutbox.isEmpty {
                activeFileEpoch = nil
                while let first = fileMessages.first {
                    fileMessages.removeFirst()
                    fileMessageBytes -= first.byteCount
                    guard first.epoch == agentFileEpoch else { continue }
                    guard first.cleanup || !peerAgentCaps.contains(AgentCapability.fileXferDisabled.rawValue) else { continue }
                    agentOutbox = first.chunks
                    agentOutboxBytes = first.byteCount
                    activeFileEpoch = first.epoch
                    break
                }
            }
            guard !agentOutbox.isEmpty else { break }
            if let activeFileEpoch, activeFileEpoch != agentFileEpoch {
                agentOutbox.removeAll(); agentOutboxBytes = 0
                continue
            }
            let chunk = agentOutbox.removeFirst()
            agentOutboxBytes -= chunk.count
            agentSendTokens -= 1
            try await connection.send(MainClientEncoder.agentData(chunk))
        }
        if agentOutbox.isEmpty { capabilityReplyQueued = false }
    }

    private func handle(_ message: SpiceMessage) async throws {
        guard let type = MainServerMessage(rawValue: message.type) else {
            log.debug("ignoring main message \(message.type)")
            return
        }
        switch type {
        case .initialize:
            let initMessage = try MainInit(decoding: message.payload)
            clock?.set(initMessage.multimediaTime)
            supportedModes = initMessage.supportedMouseModes
            currentMode = initMessage.currentMouseMode
            agentSendTokens = initMessage.agentTokens
            events.yield(.initialized(sessionID: initMessage.sessionID, mouseModes: supportedModes,
                                      currentMode: currentMode, agentConnected: initMessage.agentConnected))
            if initMessage.agentConnected { try await agentDidConnect() }
            try await connection.send(MainClientEncoder.attachChannels())
            // Prefer client mode (absolute pointer) whenever the server offers it.
            if supportedModes.contains(.client), currentMode != .client {
                try await connection.send(MainClientEncoder.mouseModeRequest(.client))
            }
        case .channelsList:
            events.yield(.monitorResizeAuthorization(monitorResizeAuthority.advance()))
            events.yield(.channels(try ChannelsList(decoding: message.payload).channels))
        case .mouseMode:
            let mode = try MainMouseMode(decoding: message.payload)
            let supportChanged = mode.supported != supportedModes
            supportedModes = mode.supported
            currentMode = mode.current
            events.yield(.mouseMode(current: mode.current, supported: mode.supported))
            // Ask for client mode once each time it becomes available (avoids request loops).
            if supportChanged, supportedModes.contains(.client), currentMode != .client {
                try await connection.send(MainClientEncoder.mouseModeRequest(.client))
            }
        case .agentConnected:
            try await agentDidConnect()
        case .agentConnectedTokens:
            agentSendTokens = try MainUInt32(decoding: message.payload).value
            try await agentDidConnect()
        case .agentDisconnected:
            retireAgentFiles()
            events.yield(.monitorResizeAuthorization(monitorResizeAuthority.advance()))
            agentConnected = false
            peerAgentCaps = CapabilitySet()
            pendingMonitorLayout = nil
            consumedAgentMessages = 0
            agentOutbox.removeAll()
            agentOutboxBytes = 0
            capabilityReplyQueued = false
            agentAssembler = AgentMessageAssembler()
            events.yield(.agentConnected(false))
        case .agentToken:
            agentSendTokens &+= try MainUInt32(decoding: message.payload).value
            try await flushAgentOutbox()
        case .agentData:
            let messages: [AgentMessage]
            do {
                messages = try agentAssembler.feed(message.payload)
            } catch {
                log.error("dropping malformed agent data: \(error)")
                messages = []
            }
            for agentMessage in messages {
                try await handleAgent(agentMessage)
            }
            consumedAgentMessages += 1
            if consumedAgentMessages >= Self.agentReceiveTokens / 2 {
                try await connection.send(MainClientEncoder.agentToken(consumedAgentMessages))
                consumedAgentMessages = 0
            }
        case .name:
            events.yield(.guestName(try MainName(decoding: message.payload).name))
        case .uuid:
            events.yield(.guestUUID(try MainUUID(decoding: message.payload).bytes))
        case .multiMediaTime:
            var reader = ByteReader(message.payload)
            clock?.set(try reader.readU32())
        case .migrateBegin, .migrateBeginSeamless, .migrateSwitchHost:
            log.info("migration requested; not supported in v1")
            throw ChannelError.migrationUnsupported
        case .migrateCancel, .migrateEnd, .migrateDstSeamlessAck, .migrateDstSeamlessNack:
            break
        }
    }

    private func agentDidConnect() async throws {
        let wasConnected = agentConnected
        agentConnected = true
        if !wasConnected {
            retireAgentFiles()
            events.yield(.monitorResizeAuthorization(monitorResizeAuthority.advance()))
            try await connection.send(MainClientEncoder.agentStart(tokens: Self.agentReceiveTokens))
            events.yield(.agentConnected(true))
            try await sendToAgent(.announceCapabilities(request: true, capabilities: Self.agentCapabilities))
        }
    }

    private func handleAgent(_ message: AgentMessage) async throws {
        switch message.knownType {
        case .announceCapabilities:
            var reader = ByteReader(message.data)
            let request = (try? reader.readU32()) ?? 0
            var words: [UInt32] = []
            while words.count < 16, let word = try? reader.readU32() { words.append(word) }
            peerAgentCaps = CapabilitySet(words: words)
            if let request = pendingMonitorLayout, request.layout.message(capabilities: peerAgentCaps) == nil {
                pendingMonitorLayout = nil
            }
            events.yield(.agentCapabilities(peerAgentCaps))
            // Our capabilities never change, so one queued reply answers any number of requests.
            if request != 0, !capabilityReplyQueued {
                capabilityReplyQueued = true
                try await sendToAgent(.announceCapabilities(request: false, capabilities: Self.agentCapabilities))
            }
        default:
            break
        }
        events.yield(.agentMessage(message))
    }
}
