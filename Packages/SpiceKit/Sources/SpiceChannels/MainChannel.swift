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
    case clipboardUnavailable
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
    private let agentAuthority = AgentAuthorizationSource()
    private let clipboardAuthority = AgentAuthorizationSource()
    private let clipboardOwnership = AgentAuthorizationSource()
    private var clipboardMessages: [QueuedAgentClipboardMessage] = []
    private var clipboardMessageBytes = 0
    private var clipboardBroken = false
    private let clipboardBuffer: ClipboardDeliveryBuffer?
    private var preferClipboard = true
    private var activeClipboardAdmission: ClipboardCommitAuthorization?
    private var fileMessages: [QueuedAgentFileMessage] = []
    private var fileMessageBytes = 0
    private var activeAgentAuthorization: AgentAuthorization?
    private var agentFlushTask: Task<Void, Never>?
    /// Messages we may still send to the agent.
    private var agentSendTokens: UInt32 = 0
    private var agentOutbox: [[UInt8]] = []
    private var agentOutboxBytes = 0
    /// Bytes queued for the agent but not yet sent (used to pace bulk transfers).
    public var pendingAgentBytes: Int { agentOutboxBytes + fileMessageBytes + clipboardMessageBytes }
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
                clock: MultimediaClock? = nil, clipboardBuffer: ClipboardDeliveryBuffer? = nil) {
        self.clipboardBuffer = clipboardBuffer
        self.clock = clock
        self.connection = connection
        self.events = events
    }

    /// Processes messages until the channel closes (throws on error or disconnect).
    public func run() async throws {
        defer {
            retireAgentLifecycle()
            agentFlushTask?.cancel()
            monitorResizeAuthority.invalidate()
            pendingMonitorLayout = nil
            peerAgentCaps = CapabilitySet()
            agentConnected = false
            clipboardBuffer?.finish()
            events.finish()
        }
        while true {
            await connection.messageHandled()
            let message = try await connection.nextMessage()
            try await handle(message)
        }
    }

    public func close() async {
        clipboardBuffer?.finish()
        retireAgentLifecycle()
        agentFlushTask?.cancel()
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
        scheduleAgentFlush()
        return true
    }

    public var fileTransferAuthorization: AgentFileTransferAuthorization? {
        agentConnected ? agentAuthority.current : nil
    }

    /// Performs no socket I/O on the caller's task. One owned sender prevents
    /// cancellation of a file task from cancelling the shared connection.
    public func enqueueFileTransfer(_ message: AgentMessage, authorization: AgentFileTransferAuthorization) throws {
        try queueFileMessage(message, authorization: authorization, cleanup: false)
    }

    public func cancelFileTransfer(id: UInt32, authorization: AgentFileTransferAuthorization) throws {
        guard agentConnected, authorization.belongs(to: agentAuthority) && authorization.isCurrent else { throw AgentFileTransferAdmissionError.unavailable }
        fileMessages.removeAll { item in
            if item.id == id { fileMessageBytes -= item.byteCount; return true }
            return false
        }
        try queueFileMessage(FileTransferCodec.status(id: id, result: .cancelled), authorization: authorization, cleanup: true)
    }

    private func queueFileMessage(_ message: AgentMessage, authorization: AgentFileTransferAuthorization, cleanup: Bool) throws {
        guard agentConnected, authorization.belongs(to: agentAuthority) && authorization.isCurrent else { throw AgentFileTransferAdmissionError.unavailable }
        guard cleanup || !peerAgentCaps.contains(AgentCapability.fileXferDisabled.rawValue) else {
            throw AgentFileTransferAdmissionError.disabledByGuest
        }
        guard [.fileXferStart, .fileXferData, .fileXferStatus].contains(message.knownType),
              message.data.count >= 4, message.data.count <= 64 * 1024 else { throw AgentFileTransferAdmissionError.invalidMessage }
        var reader = ByteReader(message.data)
        let id = try reader.readU32()
        let entry = QueuedAgentFileMessage(id: id, authorization: authorization, chunks: message.encodeChunks(), cleanup: cleanup)
        let limit = Self.maxAgentOutboxBytes - (cleanup ? 0 : 64 * 1024)
        guard fileMessages.count < (cleanup ? 80 : 64), pendingAgentBytes + entry.byteCount <= limit else {
            throw AgentFileTransferAdmissionError.queueFull
        }
        fileMessages.append(entry)
        fileMessageBytes += entry.byteCount
        scheduleAgentFlush()
    }

    private func flushOwnedAgentMessages() async {
        defer { agentFlushTask = nil }
        do { try await flushAgentOutbox() }
        catch { await connection.close() }
    }

    private func retireAgentLifecycle() {
        activeClipboardAdmission?.discardUnstarted()
        activeClipboardAdmission = nil
        agentAuthority.advance()
        clipboardAuthority.advance()
        clipboardOwnership.advance()
        for item in clipboardMessages { item.sharing.requestReceipt?.discardBeforeSend() }
        clipboardMessages.removeAll()
        clipboardMessageBytes = 0
        fileMessages.removeAll()
        fileMessageBytes = 0
        activeAgentAuthorization = nil
    }

    public var clipboardAuthorization: ClipboardAgentAuthorization? {
        guard agentConnected, !clipboardBroken, peerAgentCaps.contains(AgentCapability.clipboardByDemand.rawValue) else { return nil }
        return ClipboardAgentAuthorization(agent: agentAuthority.current, negotiation: clipboardAuthority.current,
                                           ownership: clipboardOwnership.current)
    }

    public func enqueueClipboard(_ action: AgentClipboardAction, authorization: ClipboardAgentAuthorization,
                                 sharing: ClipboardSharingAuthorization) -> Bool {
        guard let current = clipboardAuthorization, current == authorization, sharing.isCurrent else { return false }
        guard sharing.requestReceipt == nil || sharing.requestReceipt?.status == .queued else { return false }
        switch action {
        case .offer(let types):
            guard !types.isEmpty, types.count <= 2, types.allSatisfy({ $0 == .utf8Text || $0 == .png }) else { return false }
        case .request(let type): guard type == .utf8Text || type == .png else { return false }
        case .provide(let type, let bytes):
            guard bytes.count <= ClipboardCodec.maxDataSize,
                  type == .utf8Text || type == .png || bytes.isEmpty else { return false }
        case .release: break
        }
        let item = QueuedAgentClipboardMessage(action: action, agent: authorization, sharing: sharing)
        guard clipboardMessages.count < 16, pendingAgentBytes + item.byteCount <= Self.maxAgentOutboxBytes else {
            disableClipboard("outbox-limit")
            return false
        }
        clipboardMessages.append(item)
        clipboardMessageBytes += item.byteCount
        scheduleAgentFlush()
        return true
    }

    private func scheduleAgentFlush() {
        guard agentFlushTask == nil else { return }
        agentFlushTask = Task { [weak self] in
            guard let self else { return }
            await self.flushOwnedAgentMessages()
        }
    }

    private func loadClipboardMessage() {
        while agentOutbox.isEmpty, !clipboardMessages.isEmpty {
            let item = clipboardMessages.removeFirst()
            clipboardMessageBytes -= item.byteCount
            guard let current = clipboardAuthorization, current == item.agent, item.sharing.isCurrent else {
                item.sharing.requestReceipt?.discardBeforeSend()
                continue
            }
            let selection = peerAgentCaps.contains(AgentCapability.clipboardSelection.rawValue)
            let message: AgentMessage
            switch item.action {
            case .offer(let types): message = ClipboardCodec.grab(types, selectionHeader: selection)
            case .request(let type): message = ClipboardCodec.request(type, selectionHeader: selection)
            case .release: message = ClipboardCodec.release(selectionHeader: selection)
            case .provide(let type, let bytes):
                let converted = type == .utf8Text ? ClipboardCodec.textToGuest(String(decoding: bytes, as: UTF8.self),
                    guestUsesCRLF: peerAgentCaps.contains(AgentCapability.guestLineEndCRLF.rawValue)) : bytes
                // Failure is an empty response, never a truncated text/image payload.
                message = ClipboardCodec.data(type, bytes: converted.count <= ClipboardCodec.maxDataSize ? converted : [], selectionHeader: selection)
            }
            agentOutbox = message.encodeChunks()
            agentOutboxBytes = agentOutbox.reduce(0) { $0 + $1.count }
            activeAgentAuthorization = item.agent.agent
            activeClipboardAdmission = ClipboardCommitAuthorization(agent: item.agent, sharing: item.sharing)
            preferClipboard = false
        }
    }

    private func disableClipboard(_ reason: StaticString = "delivery-ended") {
        log.info("clipboard disabled: \(reason)")
        clipboardBroken = true
        clipboardAuthority.advance()
        for item in clipboardMessages { item.sharing.requestReceipt?.discardBeforeSend() }
        clipboardMessages.removeAll()
        clipboardMessageBytes = 0
        clipboardBuffer?.finish()
        events.yield(.clipboardUnavailable)
    }

    private func receiveClipboard(_ message: AgentMessage) {
        guard clipboardAuthorization != nil, let clipboardBuffer else { return }
        do {
            guard var decoded = try ClipboardCodec.decode(message,
                selectionHeader: peerAgentCaps.contains(AgentCapability.clipboardSelection.rawValue)) else { return }
            switch decoded {
            case .grab(let selection, _), .request(let selection, _), .release(let selection):
                guard selection == .clipboard else { return }
            case .data(let selection, let type, let bytes):
                guard selection == .clipboard else { return }
                if type == .utf8Text {
                    let text = ClipboardCodec.textFromGuest(bytes)
                    guard text.utf8.count <= ClipboardCodec.maxDataSize else { disableClipboard(); return }
                    decoded = .data(selection: selection, type: type, bytes: Array(text.utf8))
                }
            }
            if case .grab = decoded { clipboardOwnership.advance() }
            if case .release = decoded { clipboardOwnership.advance() }
            guard let authorization = clipboardAuthorization else { return }
            if !clipboardBuffer.yield(AgentClipboardDelivery(message: decoded, authorization: authorization)) { disableClipboard() }
        } catch { disableClipboard("malformed-control") }
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
        scheduleAgentFlush()
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
                activeAgentAuthorization = nil
                if preferClipboard || fileMessages.isEmpty { loadClipboardMessage() }
            }
            if agentOutbox.isEmpty {
                activeAgentAuthorization = nil
                while let first = fileMessages.first {
                    fileMessages.removeFirst()
                    fileMessageBytes -= first.byteCount
                    guard first.authorization.isCurrent else { continue }
                    guard first.cleanup || !peerAgentCaps.contains(AgentCapability.fileXferDisabled.rawValue) else { continue }
                    agentOutbox = first.chunks
                    agentOutboxBytes = first.byteCount
                    activeAgentAuthorization = first.authorization
                    preferClipboard = true
                    break
                }
            }
            if agentOutbox.isEmpty { loadClipboardMessage() }
            guard !agentOutbox.isEmpty else { break }
            if let activeAgentAuthorization, !activeAgentAuthorization.isCurrent {
                agentOutbox.removeAll(); agentOutboxBytes = 0
                continue
            }
            if let admission = activeClipboardAdmission {
                activeClipboardAdmission = nil
                guard admission.begin(current: clipboardAuthorization) else {
                    admission.discardUnstarted()
                    agentOutbox.removeAll(); agentOutboxBytes = 0; activeAgentAuthorization = nil
                    continue
                }
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
            retireAgentLifecycle()
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
                disableClipboard("malformed-agent-data")
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
            retireAgentLifecycle()
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
            let nextCaps = CapabilitySet(words: words)
            let clipboardBits: [AgentCapability] = [.clipboardByDemand, .clipboardSelection, .guestLineEndCRLF]
            if clipboardBits.contains(where: { peerAgentCaps.contains($0.rawValue) != nextCaps.contains($0.rawValue) }) {
                clipboardAuthority.advance()
            }
            peerAgentCaps = nextCaps
            if let request = pendingMonitorLayout, request.layout.message(capabilities: peerAgentCaps) == nil {
                pendingMonitorLayout = nil
            }
            events.yield(.agentCapabilities(peerAgentCaps))
            // Our capabilities never change, so one queued reply answers any number of requests.
            if request != 0, !capabilityReplyQueued {
                capabilityReplyQueued = true
                try await sendToAgent(.announceCapabilities(request: false, capabilities: Self.agentCapabilities))
            }
        case .clipboardGrab, .clipboardRequest, .clipboard, .clipboardRelease:
            if clipboardBuffer != nil { receiveClipboard(message); return }
        default:
            break
        }
        events.yield(.agentMessage(message))
    }
}
