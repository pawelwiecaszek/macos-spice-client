import SpiceAgent
import SpiceWire

/// Events from the main channel.
public enum MainEvent: Sendable, Equatable {
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
    /// Messages we may still send to the agent.
    private var agentSendTokens: UInt32 = 0
    private var agentOutbox: [[UInt8]] = []
    private var agentOutboxBytes = 0
    /// Bytes queued for the agent but not yet sent (used to pace bulk transfers).
    public var pendingAgentBytes: Int { agentOutboxBytes }
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
        defer { events.finish() }
        while true {
            let message = try await connection.nextMessage()
            try await handle(message)
        }
    }

    public func close() async {
        await connection.close()
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
        guard agentOutboxBytes + size <= Self.maxAgentOutboxBytes else {
            log.info("agent outbox full; dropping a type \(message.type) message")
            return
        }
        agentOutbox.append(contentsOf: chunks)
        agentOutboxBytes += size
        try await flushAgentOutbox()
    }

    private func flushAgentOutbox() async throws {
        while agentSendTokens > 0, !agentOutbox.isEmpty {
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
            agentConnected = false
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
            events.yield(.agentCapabilities(CapabilitySet(words: words)))
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
