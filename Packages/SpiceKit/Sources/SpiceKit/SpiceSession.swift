@_exported import SpiceAgent
@_exported import SpiceChannels
@_exported import SpiceCodecs
@_exported import SpiceTransport
@_exported import AudioHost
@_exported import Proxmox
@_exported import Ravada
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
    /// All server-advertised display channels, including unsupported IDs. Clients
    /// must not replace a whole monitor set while some channels remain unknown.
    case displayChannels([UInt8])
    /// Whether a linked peer promises explicit monitor metadata; a created
    /// surface alone is not proof of a legacy single-head configuration.
    case displayMonitorConfiguration(channel: UInt8, supported: Bool)
    case monitorResizeAuthorization(MonitorResizeAuthorization)
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
    /// Guest audio for one consumer. Bounded packet loss is explicit; START/STOP
    /// and other control events are never silently evicted by an audio burst.
    public nonisolated let playbackEvents: AsyncStream<PlaybackEvent>
    /// Guest requests to start/stop recording from the microphone.
    public nonisolated let recordEvents: AsyncStream<RecordEvent>
    /// Clipboard messages from the guest (CLIPBOARD selection only; text already in macOS
    /// form: LF line endings, no trailing NUL).
    public nonisolated let clipboardEvents: AsyncStream<AgentClipboardDelivery>

    private nonisolated let eventSink: AsyncStream<SessionEvent>.Continuation
    private nonisolated let displaySink: AsyncStream<DisplayEvent>.Continuation
    private nonisolated let secondaryDisplaySink: AsyncStream<SecondaryDisplayEvent>.Continuation
    private var secondaryDisplays: [UInt8: DisplayChannel] = [:]
    private nonisolated let cursorSink: AsyncStream<CursorEvent>.Continuation
    private nonisolated let usbSink: AsyncStream<USBSlotEvent>.Continuation
    private nonisolated let smartcardSink: AsyncStream<SmartcardEvent>.Continuation
    private nonisolated let playbackSink: PlaybackEventBuffer
    private nonisolated let recordSink: AsyncStream<RecordEvent>.Continuation
    private var playback: PlaybackChannel?
    private var record: RecordChannel?
    private var audio = AudioSupport()
    private nonisolated let clipboardSink: ClipboardDeliveryBuffer
    var guestAgentCaps = CapabilitySet()
    var clipboardFailed = false
    private nonisolated let monitorResizeAuthorities = (0..<SpiceSession.maxDisplays).map { _ in MonitorResizeAuthority() }
    private nonisolated let inputSink: AsyncStream<InputEvent>.Continuation
    private let inputQueue: AsyncStream<InputEvent>

    private let opener: ChannelOpener
    private nonisolated let clock = MultimediaClock()
    private let configurationError: TransportError?
    private let ticket: SecretTicket?
    private let log = ChannelLogger(category: "session")

    var state: SessionState = .idle
    let fileTransfers: SessionFileTransferState
    var main: MainChannel?
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

    public init(profile: ConnectionProfile, connector: any StreamConnector, encryptor: any TicketEncryptor,
                fileTransferStatusTimeout: Duration = .seconds(30)) {
        self.fileTransfers = SessionFileTransferState(timeout: fileTransferStatusTimeout)
        (events, eventSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (displayEvents, displaySink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (secondaryDisplayEvents, secondaryDisplaySink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        // Cursor events are self-contained state; a flood only drops stale ones.
        (cursorEvents, cursorSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
        (inputQueue, inputSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (usbEvents, usbSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (smartcardEvents, smartcardSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (playbackEvents, playbackSink) = PlaybackEventBuffer.makeStream()
        (recordEvents, recordSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        (clipboardEvents, clipboardSink) = ClipboardDeliveryBuffer.makeStream()
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
            let main = MainChannel(connection: connection, events: mainSink, clock: clock, clipboardBuffer: clipboardSink)
            self.main = main
            spawn("main", critical: true, connection: connection) { try await main.run() }
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
        var monitors: [GuestMonitor] = []
        var x: Int64 = 0
        for id in 0..<UInt8(Self.maxDisplays) {
            guard let size = sizes[id], size.width > 0, size.height > 0 else { break }
            guard size.width <= 16_384, size.height <= 16_384, let position = Int32(exactly: x) else { return }
            monitors.append(GuestMonitor(id: id, width: UInt32(size.width), height: UInt32(size.height), x: position, y: 0))
            x += Int64(size.width)
        }
        guard let layout = GuestMonitorLayout(monitors) else { return }
        _ = await requestGuestMonitorLayout(layout)
    }

    /// Submits a complete desired layout. Acceptance means queued for the current
    /// agent, not that the guest applied it. Sparse/position capabilities are
    /// checked on the main-channel owner immediately before queue admission.
    @discardableResult
    public func requestGuestMonitorLayout(_ layout: GuestMonitorLayout,
                                         authorizations: [MonitorResizeAuthorization] = []) async -> Bool {
        guard state == .connected, let main else { return false }
        return (try? await main.requestMonitorLayout(layout, authorizations: authorizations)) ?? false
    }

    // MARK: USB redirection (AGENTS.md §7a/§7b)

    /// Attaches a device to the first free slot; returns the slot number.
    @discardableResult
    ///
    /// The connection file's policy is enforced here for every device, real or emulated
    /// (ISO drives included), so no UI path can bypass it.
    public func attachUSB(_ device: any USBRedirDevice, allowInputDevice: Bool = false) async throws -> Int {
        try await attachUSBWithLease(device, allowInputDevice: allowInputDevice).slot
    }

    /// Owns one attachment, so delayed cleanup cannot detach a replacement device.
    /// Supply a fresh `attachmentID` only when correlating admission with slot events.
    public func attachUSBWithLease(_ device: any USBRedirDevice, allowInputDevice: Bool = false,
                                   attachmentID: UUID = UUID()) async throws -> USBAttachmentLease {
        guard usbAllowed else { throw USBAttachError.blockedByConnectionFile }
        guard state == .connected else { throw USBAttachError.guestNotReady }
        let description = await device.describe()
        if let localUSBFilter, !localUSBFilter.allows(description.filterDevice) {
            throw USBAttachError.blockedByConnectionFile
        }
        // Smart card readers (class 0x0B, including the emulated one) follow enable-smartcard.
        if !smartcardAllowed, description.filterDevice.classes.contains(0x0B) {
            throw USBAttachError.blockedByConnectionFile
        }
        guard state == .connected else { throw USBAttachError.guestNotReady }
        for slot in usbSlots where await slot.isFree {
            guard state == .connected else { throw USBAttachError.guestNotReady }
            try await slot.attach(device, allowInputDevice: allowInputDevice, attachmentID: attachmentID)
            let lease = USBAttachmentLease(slot: slot.slot, id: attachmentID, channel: slot)
            guard state == .connected, usbSlots.contains(where: { $0 === slot }) else {
                await lease.detach()
                throw USBAttachError.guestNotReady
            }
            return lease
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

    /// A synchronous mutex-backed lease avoids late actor hops resurrecting an
    /// older playback producer after replacement on the main actor.
    public nonisolated func beginAudioClock() -> UInt64 { clock.beginAudio() }

    @discardableResult
    public nonisolated func updateAudioClock(time: UInt32, epoch: UInt64, at: ContinuousClock.Instant,
                                            delayMilliseconds: UInt32? = nil) -> Bool {
        clock.updateAudio(time: time, epoch: epoch, at: at, delayMilliseconds: delayMilliseconds)
    }

    public nonisolated func invalidateAudioClock(epoch: UInt64) { clock.invalidateAudio(epoch: epoch) }
    public nonisolated func endAudioClock(epoch: UInt64) { clock.endAudio(epoch: epoch) }

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

    /// Current primary surface (e.g. for screenshots).
    public func snapshot() async -> PixelBuffer? {
        await display?.primarySurface()
    }

    // MARK: Internals

    private func handle(_ event: MainEvent) async {
        switch event {
        case .monitorResizeAuthorization(let authorization):
            eventSink.yield(.monitorResizeAuthorization(authorization))
        case .initialized(let id, _, let current, let agent):
            sessionID = id
            eventSink.yield(.mouseMode(current))
            eventSink.yield(.agentConnected(agent))
        case .channels(let list):
            await openChannels(list)
        case .mouseMode(let current, _):
            eventSink.yield(.mouseMode(current))
        case .clipboardUnavailable:
            clipboardFailed = true
            eventSink.yield(.clipboardAvailable(false))
        case .agentConnected(let connected):
            if !connected {
                guestAgentCaps = CapabilitySet()
                eventSink.yield(.clipboardAvailable(false))
                failFileTransfers(.agentNotConnected)
            }
            eventSink.yield(.agentConnected(connected))
        case .agentCapabilities(let caps):
            guestAgentCaps = caps
            if caps.contains(AgentCapability.fileXferDisabled.rawValue) { failFileTransfers(.disabled) }
            eventSink.yield(.clipboardAvailable(clipboardSupported))
        case .agentMessage(let message):
            if let status = FileTransferCodec.decodeStatus(message) {
                fileTransferStatus(id: status.id, result: status.result)
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
        // Each supported display channel has independent rendering/cache state.
        // The list is server-controlled: drop duplicate (type, id) pairs and cap how many
        // connections it can make us open (one per singleton channel, 16 USB slots).
        var seen = Set<ChannelsList.Entry>()
        let unique = list.filter { seen.insert($0).inserted }
        eventSink.yield(.displayChannels(unique.filter { $0.type == .display }.map(\.id).sorted()))
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
            // Declare opening peers before concurrent links; barriers may arrive first.
            try await opener.synchronization.expect(wanted.map { .init(rawType: $0.rawType, id: $0.id) })
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
                            await opener.synchronization.unavailable(.init(type: type, id: entry.id))
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
            spawn("usbredir \(id)", critical: false, connection: connection) { [weak self] in
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
            spawn("playback", critical: false, connection: connection) { try await channel.run() }
        case .record:
            let channel = RecordChannel(connection: connection, events: recordSink)
            record = channel
            spawn("record", critical: false, connection: connection) { try await channel.run() }
        case .smartcard:
            let channel = SmartcardChannel(connection: connection, events: smartcardSink)
            smartcard = channel
            spawn("smartcard", critical: false, connection: connection) { [weak self] in
                do {
                    try await channel.run()
                } catch {
                    await self?.optionalChannelClosed(smartcard: channel)
                    throw error
                }
            }
        case .display where id == 0:
            let supportsMonitors = connection.serverCaps.contains(DisplayCapability.monitorsConfig.rawValue)
            eventSink.yield(.displayMonitorConfiguration(channel: id, supported: supportsMonitors))
            let channel = DisplayChannel(connection: connection, events: displaySink, credit: displayCredit, clock: clock,
                                         monitorResizeAuthority: monitorResizeAuthorities[Int(id)])
            display = channel
            spawn("display", critical: true, connection: connection) { try await channel.run() }
        case .display:
            let supportsMonitors = connection.serverCaps.contains(DisplayCapability.monitorsConfig.rawValue)
            eventSink.yield(.displayMonitorConfiguration(channel: id, supported: supportsMonitors))
            // Additional monitor: its own stream, forwarded tagged with the display id.
            let (stream, sink) = AsyncStream<DisplayEvent>.makeStream(bufferingPolicy: .unbounded)
            let channel = DisplayChannel(connection: connection, events: sink,
                                         credit: secondaryDisplayCredits[Int(id) - 1], clock: clock,
                                         monitorResizeAuthority: monitorResizeAuthorities[Int(id)])
            secondaryDisplays[id] = channel
            let forward = secondaryDisplaySink
            tasks.append(Task {
                for await event in stream { forward.yield(SecondaryDisplayEvent(display: id, event: event)) }
                forward.yield(SecondaryDisplayEvent(display: id, event: .primarySurfaceDestroyed(surfaceID: 0)))
            })
            spawn("display \(id)", critical: false, connection: connection) { try await channel.run() }
        case .inputs:
            let channel = InputsChannel(connection: connection)
            inputs = channel
            spawn("inputs", critical: true, connection: connection) { try await channel.run() }
        case .cursor:
            let channel = CursorChannel(connection: connection, events: cursorSink)
            cursor = channel
            spawn("cursor", critical: false, connection: connection) { try await channel.run() }
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

    private func spawn(_ name: String, critical: Bool, connection: ChannelConnection,
                       _ body: @escaping @Sendable () async throws -> Void) {
        tasks.append(Task { [weak self] in
            do {
                try await body()
                await connection.close()
            } catch {
                // A failed handler must close its ordering identity before peers can wait.
                await connection.close()
                if error is CancellationError { return }
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
        clock.reset()
        // Wake barriers before sequential channel close awaits; old sessions cannot
        // publish progress into a replacement session's independent opener/coordinator.
        for authority in monitorResizeAuthorities { authority.invalidate() }
        await opener.synchronization.shutdown()
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
