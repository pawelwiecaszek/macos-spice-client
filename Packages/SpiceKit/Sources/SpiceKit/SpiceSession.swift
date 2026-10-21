@_exported import SpiceAgent
@_exported import SpiceChannels
@_exported import SpiceCodecs
@_exported import SpiceTransport
@_exported import AudioHost
@_exported import Proxmox
@_exported import SmartcardHost
@_exported import SpiceWire
@_exported import USBEmulation
@_exported import USBHost
@_exported import USBRedirWire
@_exported import VVFile
import Foundation

/// Lifecycle of a session.
public enum SessionState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case disconnected(SessionFailure?)
}

/// A user-presentable reason a session ended.
public struct SessionFailure: Error, Sendable, Equatable, LocalizedError {
    /// What reconnecting could achieve (M8).
    public enum Recovery: Sendable, Equatable {
        /// The network dropped or timed out: reconnecting automatically is worthwhile.
        case automatic
        /// The server or its proxy ended the session (guest shut down, another client took
        /// over, ticket expired): reconnect only when the user asks.
        case manual
        /// The same settings would fail again (security, configuration, protocol errors).
        case none
    }

    public var message: String
    /// `true` when re-downloading the `.vv` file is the likely fix.
    public var isAuthenticationFailure: Bool
    public var recovery: Recovery

    public init(message: String, isAuthenticationFailure: Bool = false, recovery: Recovery = .none) {
        self.message = message
        self.isAuthenticationFailure = isAuthenticationFailure
        self.recovery = recovery
    }

    public var errorDescription: String? { message }

    init(_ error: any Error) {
        switch error {
        case let transport as TransportError:
            switch transport {
            case .authenticationFailed:
                self.init(message: transport.localizedDescription, isAuthenticationFailure: true, recovery: .manual)
            case .proxyRefused(let status) where status == 401 || status == 403:
                self.init(message: transport.localizedDescription, isAuthenticationFailure: true, recovery: .manual)
            case .timedOut, .connectionFailed:
                self.init(message: transport.localizedDescription, recovery: .automatic)
            case .closed, .proxyRefused:
                self.init(message: transport.localizedDescription, recovery: .manual)
            default:
                self.init(message: transport.localizedDescription)
            }
        case ChannelError.serverDisconnected:
            self.init(message: "The server ended the session.", recovery: .manual)
        case ChannelError.migrationUnsupported:
            self.init(message: "The virtual machine is migrating to another host.", recovery: .automatic)
        default:
            self.init(message: "The session ended unexpectedly (\(error)).", recovery: .manual)
        }
    }
}

/// Session-level notifications for the UI.
public enum SessionEvent: Sendable, Equatable {
    case state(SessionState)
    case mouseMode(MouseModes)
    case agentConnected(Bool)
    case guestName(String)
    /// Number of USB redirection slots the VM offers (0 = none / disabled by the `.vv`).
    case usbSlots(Int)
    /// Whether the VM has a smartcard reader that Mac cards can be shared into.
    case smartcardAvailable(Bool)
    /// Whether the guest agent can share the clipboard.
    case clipboardAvailable(Bool)
}

/// Public façade: one SPICE session (main + display + inputs + cursor channels).
///
/// Consume `events`, `displayEvents` and `cursorEvents` on the main actor; call `send(_:)`
/// from UI code (it never blocks).
public actor SpiceSession {
    public nonisolated let events: AsyncStream<SessionEvent>
    public nonisolated let displayEvents: AsyncStream<DisplayEvent>
    /// Call `consumed()` after applying each `.update` from `displayEvents`.
    public nonisolated let displayCredit = DisplayUpdateCredit()
    /// Events of additional monitors (display channels 1…`maxDisplays`-1, e.g. Proxmox
    /// "SPICE dual/quad monitor"), tagged with the display id. Display 0 uses `displayEvents`.
    public nonisolated let secondaryDisplayEvents: AsyncStream<SecondaryDisplayEvent>
    /// Backpressure credits for displays 1…; index = display id − 1.
    public nonisolated let secondaryDisplayCredits: [DisplayUpdateCredit] =
        (1..<SpiceSession.maxDisplays).map { _ in DisplayUpdateCredit() }
    public static let maxDisplays = 4
    public nonisolated let cursorEvents: AsyncStream<CursorEvent>
    public nonisolated let usbEvents: AsyncStream<USBSlotEvent>
    public nonisolated let smartcardEvents: AsyncStream<SmartcardEvent>
    /// Guest audio to play (bounded: about 5 s of 10 ms packets; older ones are dropped).
    public nonisolated let playbackEvents: AsyncStream<PlaybackEvent>
    /// Guest requests to start/stop recording from the microphone.
    public nonisolated let recordEvents: AsyncStream<RecordEvent>
    /// Clipboard messages from the guest (CLIPBOARD selection only; text already in macOS
    /// form: LF line endings, no trailing NUL).
    public nonisolated let clipboardEvents: AsyncStream<ClipboardMessage>

    private nonisolated let eventSink: AsyncStream<SessionEvent>.Continuation
    private nonisolated let displaySink: AsyncStream<DisplayEvent>.Continuation
    private nonisolated let secondaryDisplaySink: AsyncStream<SecondaryDisplayEvent>.Continuation
    private var secondaryDisplays: [UInt8: DisplayChannel] = [:]
    private nonisolated let cursorSink: AsyncStream<CursorEvent>.Continuation
    private nonisolated let usbSink: AsyncStream<USBSlotEvent>.Continuation
    private nonisolated let smartcardSink: AsyncStream<SmartcardEvent>.Continuation
    private nonisolated let playbackSink: AsyncStream<PlaybackEvent>.Continuation
    private nonisolated let recordSink: AsyncStream<RecordEvent>.Continuation
    private var playback: PlaybackChannel?
    private var record: RecordChannel?
    private var audio = AudioSupport()
    private nonisolated let clipboardSink: AsyncStream<ClipboardMessage>.Continuation
    private var guestAgentCaps = CapabilitySet()
    private nonisolated let inputSink: AsyncStream<InputEvent>.Continuation
    private let inputQueue: AsyncStream<InputEvent>

    private let opener: ChannelOpener
    private let clock = MultimediaClock()
    private let configurationError: TransportError?
    private let ticket: SecretTicket?
    private let log = ChannelLogger(category: "session")

    private var state: SessionState = .idle
    private var main: MainChannel?
    private var display: DisplayChannel?
    private var inputs: InputsChannel?
    private var cursor: CursorChannel?
    private var usbSlots: [USBRedirChannel] = []
    private let usbAllowed: Bool
    static let maxUSBSlots = 16
    private let localUSBFilter: USBFilter?
    private var smartcard: SmartcardChannel?
    /// `enable-smartcard=0` disables smartcards on every transport (channel and USB reader).
    public nonisolated let smartcardAllowed: Bool
    private var tasks: [Task<Void, Never>] = []
    private var sessionID: UInt32?
    private var channelsRequested = false

    public init(profile: ConnectionProfile, connector: any StreamConnector, encryptor: any TicketEncryptor) {
        (events, eventSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (displayEvents, displaySink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (secondaryDisplayEvents, secondaryDisplaySink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        // Cursor events are self-contained state; a flood only drops stale ones.
        (cursorEvents, cursorSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
        (inputQueue, inputSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (usbEvents, usbSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (smartcardEvents, smartcardSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (playbackEvents, playbackSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(500))
        (recordEvents, recordSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        (clipboardEvents, clipboardSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        usbAllowed = profile.enableUSBRedirection != false
        localUSBFilter = profile.usbFilter
        smartcardAllowed = profile.enableSmartcard != false
        let ticket = profile.password
        self.ticket = ticket
        let endpoint: SpiceEndpoint
        do {
            endpoint = try Self.endpoint(for: profile)
            configurationError = nil
        } catch {
            // Never fall back to weaker checks: the session fails on connect() instead.
            endpoint = SpiceEndpoint(host: profile.host)
            configurationError = error
        }
        opener = ChannelOpener(endpoint: endpoint, connector: connector, encryptor: encryptor) {
            ticket?.withBytes { $0 }
        }
    }

    #if canImport(Network) && canImport(Security)
    /// Uses Network.framework and Security.framework.
    public init(profile: ConnectionProfile) {
        self.init(profile: profile, connector: NetworkConnector(), encryptor: SecurityTicketEncryptor())
    }
    #endif

    /// Translates a `.vv` profile into transport settings.
    ///
    /// Throws when a supplied CA or `host-subject` can't be used: a security setting that
    /// can't be honoured must not silently become a weaker one (system trust, hostname check).
    public static func endpoint(for profile: ConnectionProfile) throws(TransportError) -> SpiceEndpoint {
        var anchors: [[UInt8]] = []
        if let caPEM = profile.caPEM {
            anchors = PEM.certificates(in: caPEM)
            let blocks = caPEM.components(separatedBy: "-----BEGIN CERTIFICATE-----").count - 1
            guard !anchors.isEmpty, anchors.count == blocks,
                  anchors.allSatisfy({ X509.subject(ofCertificate: $0) != nil }) else {
                throw .insecureConfiguration("the CA certificate can’t be read")
            }
        }
        var subject: [X509.NameAttribute]?
        if let text = profile.hostSubject {
            guard let parsed = HostSubject.parse(text) else {
                throw .insecureConfiguration("the expected server certificate subject can’t be read")
            }
            subject = parsed
        }
        let secure: SpiceEndpoint.SecureChannels
        switch profile.secureChannels {
        case .unspecified: secure = .unspecified
        case .all: secure = .all
        case .some(let names):
            secure = .some(Set(names.compactMap { name in
                ChannelType.allCases.first { $0.description == name.rawValue }
            }))
        }
        return SpiceEndpoint(
            host: profile.host,
            port: profile.port,
            tlsPort: profile.tlsPort,
            proxy: profile.proxy.map { SpiceEndpoint.Proxy(host: $0.host, port: $0.port) },
            trustAnchors: anchors,
            hostSubject: subject,
            secureChannels: secure
        )
    }

    // MARK: Lifecycle

    /// Connects the main channel; other channels follow once the server lists them.
    public func connect() async {
        guard state == .idle else { return }
        setState(.connecting)
        if let configurationError {
            fail(configurationError)
            return
        }
        do {
            let connection = try await opener.open(type: .main, id: 0, connectionID: 0,
                                                   channelCaps: MainChannel.capabilities)
            // The user may have disconnected while we were linking.
            guard state == .connecting else {
                await connection.close()
                return
            }
            let (mainEvents, mainSink) = AsyncStream<MainEvent>.makeStream()
            let main = MainChannel(connection: connection, events: mainSink, clock: clock)
            self.main = main
            spawn("main", critical: true) { try await main.run() }
            tasks.append(Task { [weak self] in
                for await event in mainEvents { await self?.handle(event) }
            })
            tasks.append(Task { [weak self, inputQueue] in
                for await input in inputQueue { await self?.forward(input) }
            })
        } catch {
            fail(error)
        }
    }

    public func disconnect() async {
        await teardown(reason: nil)
    }

    /// Queues user input; dropped silently if the inputs channel is not up.
    public nonisolated func send(_ event: InputEvent) {
        inputSink.yield(event)
    }

    /// Asks the guest agent to resize the guest display (pixels). Requires vdagent.
    public func requestGuestResolution(width: Int, height: Int) async {
        await requestGuestMonitors([0: (width, height)])
    }

    /// Asks the guest agent for one monitor per display id, laid out left to right.
    /// Ids must be contiguous from 0; a missing id ends the list.
    public func requestGuestMonitors(_ sizes: [UInt8: (width: Int, height: Int)]) async {
        guard let main else { return }
        var monitors: [(width: UInt32, height: UInt32, x: Int32, y: Int32)] = []
        var x: Int32 = 0
        for id in 0..<UInt8(Self.maxDisplays) {
            guard let size = sizes[id], size.width > 0, size.height > 0 else { break }
            monitors.append((UInt32(size.width), UInt32(size.height), x, 0))
            x += Int32(size.width)
        }
        guard !monitors.isEmpty else { return }
        try? await main.sendToAgent(.monitorsConfig(monitors))
    }

    // MARK: USB redirection (AGENTS.md §7a/§7b)

    /// Attaches a device to the first free slot; returns the slot number.
    @discardableResult
    ///
    /// The connection file's policy is enforced here for every device, real or emulated
    /// (ISO drives included), so no UI path can bypass it.
    public func attachUSB(_ device: any USBRedirDevice, allowInputDevice: Bool = false) async throws -> Int {
        guard usbAllowed else { throw USBAttachError.blockedByConnectionFile }
        let description = await device.describe()
        if let localUSBFilter, !localUSBFilter.allows(description.filterDevice) {
            throw USBAttachError.blockedByConnectionFile
        }
        // Smart card readers (class 0x0B, including the emulated one) follow enable-smartcard.
        if !smartcardAllowed, description.filterDevice.classes.contains(0x0B) {
            throw USBAttachError.blockedByConnectionFile
        }
        for slot in usbSlots where await slot.isFree {
            try await slot.attach(device, allowInputDevice: allowInputDevice)
            return slot.slot
        }
        throw USBAttachError.slotBusy
    }

    public func detachUSB(slot number: Int) async {
        await usbSlots.first { $0.slot == number }?.detach()
    }

    /// Name of the device in each slot (`nil` = free), ordered by slot.
    public func usbSlotStates() async -> [(slot: Int, device: String?)] {
        var states: [(slot: Int, device: String?)] = []
        for slot in usbSlots { states.append((slot.slot, await slot.attachedName)) }
        return states
    }

    // MARK: Audio (M7)

    /// What the host can do; set before `connect()` (it decides which channels are linked
    /// and which codecs are advertised).
    public struct AudioSupport: Sendable {
        public var playback = false
        public var opusDecode = false
        public var record = false
        public var opusEncode = false
        public init(playback: Bool = false, opusDecode: Bool = false, record: Bool = false, opusEncode: Bool = false) {
            self.playback = playback
            self.opusDecode = opusDecode
            self.record = record
            self.opusEncode = opusEncode
        }
    }

    public func configureAudio(_ support: AudioSupport) {
        audio = support
    }

    /// Sends captured microphone audio (raw S16LE or one Opus frame) while the guest records.
    public func sendMicrophone(_ bytes: [UInt8], mode: AudioDataMode) async {
        guard let record else { return }
        await record.send(bytes, mode: mode, time: clock.now ?? 0)
    }

    // MARK: Smartcard sharing

    /// Shares `card` with the guest's virtual reader.
    public func insertSmartcard(_ card: any SmartcardCard) async throws {
        guard let smartcard else { throw SmartcardError.readerNotAccepted }
        try await smartcard.insert(card)
    }

    /// Takes the shared card back from the guest.
    public func removeSmartcard() async {
        await smartcard?.remove()
    }

    // MARK: Clipboard (vdagent, AGENTS.md M6)

    /// The guest agent supports on-demand clipboard sharing.
    public var clipboardSupported: Bool { guestAgentCaps.contains(AgentCapability.clipboardByDemand.rawValue) }
    private var selectionHeader: Bool { guestAgentCaps.contains(AgentCapability.clipboardSelection.rawValue) }
    private var guestUsesCRLF: Bool { guestAgentCaps.contains(AgentCapability.guestLineEndCRLF.rawValue) }

    /// Tells the guest the Mac clipboard now holds `types` (data follows on request).
    public func offerClipboard(_ types: [ClipboardDataType]) async {
        guard clipboardSupported, !types.isEmpty else { return }
        await sendAgent(ClipboardCodec.grab(types, selectionHeader: selectionHeader))
    }

    /// Answers a guest request. Text is given in macOS form and converted for the guest.
    public func provideClipboard(_ type: ClipboardDataType, data: [UInt8]) async {
        guard clipboardSupported else { return }
        let payload = type == .utf8Text
            ? ClipboardCodec.textToGuest(String(decoding: data, as: UTF8.self), guestUsesCRLF: guestUsesCRLF)
            : data
        await sendAgent(ClipboardCodec.data(type, bytes: payload, selectionHeader: selectionHeader))
    }

    /// Asks the guest for the clipboard contents it offered.
    public func requestClipboard(_ type: ClipboardDataType) async {
        guard clipboardSupported else { return }
        await sendAgent(ClipboardCodec.request(type, selectionHeader: selectionHeader))
    }

    /// Withdraws an earlier offer (the Mac clipboard no longer has shareable data).
    public func releaseClipboard() async {
        guard clipboardSupported else { return }
        await sendAgent(ClipboardCodec.release(selectionHeader: selectionHeader))
    }

    private func sendAgent(_ message: AgentMessage) async {
        guard let main else { return }
        do {
            try await main.sendToAgent(message)
        } catch {
            log.debug("agent send failed: \(error)")
        }
    }

    // MARK: File transfer (drag & drop to the guest)

    public enum FileTransferError: Error, Equatable, Sendable, LocalizedError {
        case agentUnavailable
        case disabledByGuest
        case rejected(FileTransferResult)
        case notAFile
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .agentUnavailable: "The SPICE guest agent (spice-vdagent) isn’t running in the virtual machine."
            case .disabledByGuest: "File transfer is disabled in the virtual machine."
            case .rejected(.notEnoughSpace): "There isn’t enough free space in the virtual machine."
            case .rejected(.sessionLocked): "The virtual machine’s session is locked."
            case .rejected(.cancelled): "The transfer was cancelled."
            case .rejected: "The virtual machine couldn’t save the file."
            case .notAFile: "Only files can be sent, not folders."
            case .unreadable: "The file couldn’t be read."
            }
        }
    }

    private var nextFileTransferID: UInt32 = 1
    private var fileTransferWaiters: [UInt32: CheckedContinuation<FileTransferResult, Never>] = [:]
    /// Statuses that arrived before anyone waited for them (actor reentrancy).
    private var earlyFileTransferStatus: [UInt32: FileTransferResult] = [:]

    /// Copies a file into the guest (it lands in the agent's download folder). `progress`
    /// receives bytes sent so far. Cancelling the task cancels the transfer.
    public func sendFile(_ url: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard let main, await main.isAgentConnected else { throw FileTransferError.agentUnavailable }
        guard !guestAgentCaps.contains(AgentCapability.fileXferDisabled.rawValue) else { throw FileTransferError.disabledByGuest }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { throw FileTransferError.notAFile }
        let size = Int64(values?.fileSize ?? 0)
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw FileTransferError.unreadable }
        defer { try? handle.close() }

        let id = nextFileTransferID
        nextFileTransferID &+= 1
        try await main.sendToAgent(FileTransferCodec.start(id: id, name: url.lastPathComponent, size: UInt64(size)))
        let first = await waitForFileStatus(id)
        guard first == .canSendData else { throw FileTransferError.rejected(first) }

        var sent: Int64 = 0
        do {
            while sent < size {
                try Task.checkCancellation()
                // Pace by the agent's flow control: keep at most ~1 MiB queued.
                while await main.pendingAgentBytes > 1024 * 1024 {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard let chunk = try handle.read(upToCount: FileTransferCodec.chunkSize), !chunk.isEmpty else {
                    throw FileTransferError.unreadable
                }
                try await main.sendToAgent(FileTransferCodec.data(id: id, bytes: Array(chunk)[...]))
                sent += Int64(chunk.count)
                progress(sent, size)
            }
        } catch {
            try? await main.sendToAgent(FileTransferCodec.status(id: id, result: .cancelled))
            fileTransferWaiters.removeValue(forKey: id)?.resume(returning: .cancelled)
            throw error
        }
        let result = await waitForFileStatus(id)
        guard result == .success else { throw FileTransferError.rejected(result) }
    }

    private func waitForFileStatus(_ id: UInt32) async -> FileTransferResult {
        if let early = earlyFileTransferStatus.removeValue(forKey: id) { return early }
        return await withCheckedContinuation { continuation in
            fileTransferWaiters[id] = continuation
        }
    }

    private func fileTransferStatus(id: UInt32, result: FileTransferResult) {
        if let waiter = fileTransferWaiters.removeValue(forKey: id) {
            waiter.resume(returning: result)
        } else if id < nextFileTransferID, earlyFileTransferStatus.count < 64 {
            earlyFileTransferStatus[id] = result
        }
    }

    /// Ends every waiting transfer (agent gone, session over).
    private func failFileTransfers(_ result: FileTransferResult) {
        let waiters = fileTransferWaiters
        fileTransferWaiters.removeAll()
        earlyFileTransferStatus.removeAll()
        for waiter in waiters.values { waiter.resume(returning: result) }
    }

    private func handleClipboard(_ message: AgentMessage) {
        let decoded: ClipboardMessage?
        do {
            decoded = try ClipboardCodec.decode(message, selectionHeader: selectionHeader)
        } catch {
            log.info("dropping clipboard message: \(error)")
            return
        }
        guard var decoded else { return }
        switch decoded {
        case .grab(let selection, _), .request(let selection, _), .release(let selection):
            guard selection == .clipboard else { return }
        case .data(let selection, let type, let bytes):
            guard selection == .clipboard else { return }
            if type == .utf8Text {
                decoded = .data(selection: selection, type: type, bytes: Array(ClipboardCodec.textFromGuest(bytes).utf8))
            }
        }
        clipboardSink.yield(decoded)
    }

    /// Current primary surface (e.g. for screenshots).
    public func snapshot() async -> PixelBuffer? {
        await display?.primarySurface()
    }

    // MARK: Internals

    private func handle(_ event: MainEvent) async {
        switch event {
        case .initialized(let id, _, let current, let agent):
            sessionID = id
            eventSink.yield(.mouseMode(current))
            eventSink.yield(.agentConnected(agent))
        case .channels(let list):
            await openChannels(list)
        case .mouseMode(let current, _):
            eventSink.yield(.mouseMode(current))
        case .agentConnected(let connected):
            if !connected {
                guestAgentCaps = CapabilitySet()
                failFileTransfers(.agentNotConnected)
            }
            eventSink.yield(.agentConnected(connected))
        case .agentCapabilities(let caps):
            guestAgentCaps = caps
            eventSink.yield(.clipboardAvailable(clipboardSupported))
        case .agentMessage(let message):
            if let status = FileTransferCodec.decodeStatus(message) {
                fileTransferStatus(id: status.id, result: status.result)
            } else {
                handleClipboard(message)
            }
        case .guestName(let name):
            eventSink.yield(.guestName(name))
        case .guestUUID:
            break
        }
    }

    private func openChannels(_ list: [ChannelsList.Entry]) async {
        guard !channelsRequested, let sessionID else { return }
        channelsRequested = true
        let opener = self.opener
        let audioCaps = audio
        // Only the first display channel is rendered in v1 (multi-monitor groundwork in M6).
        // The list is server-controlled: drop duplicate (type, id) pairs and cap how many
        // connections it can make us open (one per singleton channel, 16 USB slots).
        var seen = Set<ChannelsList.Entry>()
        let unique = list.filter { seen.insert($0).inserted }
        var usbCount = 0
        let wanted = unique.filter { entry in
            switch entry.type {
            case .display:
                return Int(entry.id) < Self.maxDisplays  // one window per monitor
            case .inputs, .cursor:
                return entry.id == 0
            case .usbredir:
                // All slots are linked now: Proxmox tickets expire, so slots can't be opened later.
                guard usbAllowed, usbCount < Self.maxUSBSlots else { return false }
                usbCount += 1
                return true
            case .smartcard:
                return smartcardAllowed && entry.id == 0
            case .playback:
                return audio.playback && entry.id == 0
            case .record:
                return audio.record && entry.id == 0
            default:
                return false
            }
        }
        log.info("server lists \(list.count) channels; opening \(wanted.count)")
        do {
            try await withThrowingTaskGroup(of: ChannelConnection?.self) { group in
                for entry in wanted {
                    guard let type = entry.type else { continue }
                    let caps: CapabilitySet = switch type {
                    case .display: DisplayChannel.capabilities
                    case .inputs: InputsChannel.capabilities
                    case .usbredir: USBRedirChannel.capabilities
                    case .smartcard: SmartcardChannel.capabilities
                    case .playback: PlaybackChannel.capabilities(opus: audioCaps.opusDecode)
                    case .record: RecordChannel.capabilities(opus: audioCaps.opusEncode)
                    default: CursorChannel.capabilities
                    }
                    group.addTask {
                        do {
                            return try await opener.open(type: type, id: entry.id, connectionID: sessionID, channelCaps: caps)
                        } catch where [ChannelType.usbredir, .smartcard, .playback, .record].contains(type) {
                            return nil  // optional devices must not end the session
                        }
                    }
                }
                // The connection carries its own type/id (a tuple result here was observed
                // to arrive as main:0 in optimized builds).
                for try await connection in group {
                    guard let connection else {
                        log.info("an optional channel (USB slot or smartcard) could not be opened")
                        continue
                    }
                    log.info("\(connection.type):\(connection.id) ready")
                    if state == .connecting {
                        attach(connection.type, id: connection.id, connection)
                    } else {
                        await connection.close()
                    }
                }
            }
        } catch {
            log.sensitive("opening channels failed:", ChannelLogger.sanitize("\(error)"))
            fail(error)
            return
        }
        // Every channel authenticated with the one-time ticket; forget it.
        ticket?.wipe()
        guard state == .connecting else { return }
        usbSlots.sort { $0.slot < $1.slot }
        setState(.connected)
        log.info("session connected; \(usbSlots.count) USB slot(s)")
        eventSink.yield(.usbSlots(usbSlots.count))
        eventSink.yield(.smartcardAvailable(smartcard != nil))
    }

    private func attach(_ type: ChannelType, id: UInt8, _ connection: ChannelConnection) {
        switch type {
        case .usbredir:
            let channel = USBRedirChannel(slot: Int(id), connection: connection, events: usbSink)
            usbSlots.append(channel)
            spawn("usbredir \(id)", critical: false) { [weak self] in
                do {
                    try await channel.run()
                } catch {
                    await self?.optionalChannelClosed(usbSlot: channel)
                    throw error
                }
            }
        case .playback:
            let channel = PlaybackChannel(connection: connection, events: playbackSink)
            playback = channel
            spawn("playback", critical: false) { try await channel.run() }
        case .record:
            let channel = RecordChannel(connection: connection, events: recordSink)
            record = channel
            spawn("record", critical: false) { try await channel.run() }
        case .smartcard:
            let channel = SmartcardChannel(connection: connection, events: smartcardSink)
            smartcard = channel
            spawn("smartcard", critical: false) { [weak self] in
                do {
                    try await channel.run()
                } catch {
                    await self?.optionalChannelClosed(smartcard: channel)
                    throw error
                }
            }
        case .display where id == 0:
            let channel = DisplayChannel(connection: connection, events: displaySink, credit: displayCredit, clock: clock)
            display = channel
            spawn("display", critical: true) { try await channel.run() }
        case .display:
            // Additional monitor: its own stream, forwarded tagged with the display id.
            let (stream, sink) = AsyncStream<DisplayEvent>.makeStream(bufferingPolicy: .unbounded)
            let channel = DisplayChannel(connection: connection, events: sink,
                                         credit: secondaryDisplayCredits[Int(id) - 1], clock: clock)
            secondaryDisplays[id] = channel
            let forward = secondaryDisplaySink
            tasks.append(Task {
                for await event in stream { forward.yield(SecondaryDisplayEvent(display: id, event: event)) }
                forward.yield(SecondaryDisplayEvent(display: id, event: .primarySurfaceDestroyed(surfaceID: 0)))
            })
            spawn("display \(id)", critical: false) { try await channel.run() }
        case .inputs:
            let channel = InputsChannel(connection: connection)
            inputs = channel
            spawn("inputs", critical: true) { try await channel.run() }
        case .cursor:
            let channel = CursorChannel(connection: connection, events: cursorSink)
            cursor = channel
            spawn("cursor", critical: false) { try await channel.run() }
        default:
            break
        }
    }

    private func forward(_ input: InputEvent) async {
        guard let inputs else { return }
        do {
            try await inputs.send(input)
        } catch {
            log.debug("input dropped: \(error)")
        }
    }

    private func spawn(_ name: String, critical: Bool, _ body: @escaping @Sendable () async throws -> Void) {
        tasks.append(Task { [weak self] in
            do {
                try await body()
            } catch is CancellationError {
                return
            } catch {
                await self?.channelEnded(name, critical: critical, error: error)
            }
        })
    }

    /// A USB slot or the smartcard channel ended while the session goes on: the channel
    /// already released its device/card; drop it and tell the UI.
    private func optionalChannelClosed(usbSlot: USBRedirChannel? = nil, smartcard closedCard: SmartcardChannel? = nil) {
        guard state == .connected || state == .connecting else { return }
        if let usbSlot, let index = usbSlots.firstIndex(where: { $0 === usbSlot }) {
            usbSlots.remove(at: index)
            eventSink.yield(.usbSlots(usbSlots.count))
        }
        if let closedCard, smartcard === closedCard {
            smartcard = nil
            eventSink.yield(.smartcardAvailable(false))
        }
    }

    private func channelEnded(_ name: String, critical: Bool, error: any Error) async {
        if case .disconnected = state { return }
        log.sensitive("\(name) channel ended:", ChannelLogger.sanitize("\(error)"))
        if critical { fail(error) }
    }

    private func fail(_ error: any Error) {
        Task { await teardown(reason: SessionFailure(error)) }
    }

    private func teardown(reason: SessionFailure?) async {
        if case .disconnected = state { return }
        setState(.disconnected(reason))
        failFileTransfers(.cancelled)
        for task in tasks { task.cancel() }
        ticket?.wipe()
        let channels: [@Sendable () async -> Void] = [
            { [main] in await main?.close() },
            { [display] in await display?.close() },
            { [secondaryDisplays] in for channel in secondaryDisplays.values { await channel.close() } },
            { [inputs] in await inputs?.close() },
            { [cursor] in await cursor?.close() },
            { [usbSlots] in for slot in usbSlots { await slot.close() } },
            { [smartcard] in await smartcard?.close() },
            { [playback, record] in
                await playback?.close()
                await record?.close()
            },
        ]
        for close in channels { await close() }
        for task in tasks { task.cancel() }
        tasks.removeAll()
        inputSink.finish()
        displaySink.finish()
        secondaryDisplaySink.finish()
        cursorSink.finish()
        usbSink.finish()
        smartcardSink.finish()
        playbackSink.finish()
        recordSink.finish()
        clipboardSink.finish()
        eventSink.finish()
    }

    private func setState(_ newState: SessionState) {
        if case .disconnected = state { return }  // terminal
        state = newState
        eventSink.yield(.state(newState))
    }
}
