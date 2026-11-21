import Foundation
import SpiceCodecs
import SpiceWire
import USBRedirWire

/// Why a device left its slot.
public enum USBDetachReason: Sendable, Equatable {
    case userRequest
    case guestRejected
    case deviceGone
    case channelClosed
}

/// Events from usbredir slots.
public enum USBSlotEvent: Sendable, Equatable {
    case attached(slot: Int, name: String)
    case detached(slot: Int, reason: USBDetachReason)
    /// Identifies the attachment that ended, even if the slot has since been reused.
    case attachmentEnded(slot: Int, attachmentID: UUID, reason: USBDetachReason)
}

public enum USBAttachError: Error, Equatable, Sendable {
    case slotBusy
    case guestNotReady
    case rejectedByGuestFilter
    case keyboardOrMouse
    /// The connection file's `usb-filter` (or `enable-usbredir=0`) forbids this device.
    case blockedByConnectionFile
}

/// One usbredir slot: a spicevmc channel carrying the usbredir protocol, with this client
/// acting as the usb-host (AGENTS.md §7a). Devices attach/detach on the open channel.
public actor USBRedirChannel {
    public static let capabilities = CapabilitySet(bits: [SpiceVMCCapability.dataCompressLZ4.rawValue])
    /// Upper bound for spicevmc compressed payloads.
    static let maxUncompressedSize = 64 * 1024 * 1024

    public nonisolated let slot: Int
    private let connection: ChannelConnection
    private let events: AsyncStream<USBSlotEvent>.Continuation
    private let log: ChannelLogger

    private var codec = USBRedirCodec()
    private var guestHelloReceived = false
    private var helloWaiters: [CheckedContinuation<Bool, Never>] = []
    private var helloWaiterID: UUID?
    private var guestFilter: USBFilter?

    private var device: (any USBRedirDevice)?
    private var deviceName = ""
    private var endpointQueues: [UInt8: AsyncStream<@Sendable () async -> Void>.Continuation] = [:]
    private var queueTasks: [Task<Void, Never>] = []
    private var interruptPollers: [UInt8: Task<Void, Never>] = [:]
    private var interruptPacketID: [UInt8: UInt64] = [:]
    private var cancelledIDs: Set<UInt64> = []
    private var inFlight: [UInt64: (endpoint: UInt8, bytes: Int)] = [:]
    private var outstandingBytes = 0
    private var attaching = false
    private var detaching = false
    private var attachmentID: UUID?
    private var disconnectTask: (id: UUID, task: Task<Void, Never>)?
    private var cleanupID: UUID?
    private var cleanupWaiters: [CheckedContinuation<Void, Never>] = []
    private var interruptPollerTokens: [UInt8: UUID] = [:]
    private var closed = false
    /// Endpoint address → transfer type of the attached device's current configuration.
    private var endpointTypes: [UInt8: USBTransferType] = [:]
    private var disconnectAckWaiter: CheckedContinuation<Void, Never>?
    private var disconnectAckID: UUID?

    public init(slot: Int, connection: ChannelConnection, events: AsyncStream<USBSlotEvent>.Continuation) {
        self.slot = slot
        self.connection = connection
        self.events = events
        self.log = ChannelLogger(category: "usbredir")
    }

    public var isFree: Bool { device == nil && !attaching && !detaching && !closed }
    public var attachedName: String? { device == nil ? nil : deviceName }

    // MARK: Channel loop

    public func run() async throws {
        defer {
            closed = true
            for waiter in helloWaiters { waiter.resume(returning: false) }
            helloWaiters.removeAll()
            resumeDisconnectAck()
        }
        do {
            try await receiveLoop()
        } catch {
            // Any exit (EOF, transport error, bad data) releases the device right away,
            // not only at session teardown.
            closed = true
            await detachLocally(.channelClosed)
            await connection.close()
            throw error
        }
    }

    private func receiveLoop() async throws {
        try await sendRaw(codec.encodeHello())
        while true {
            await connection.messageHandled()
            let message = try await connection.nextMessage()
            let bytes: [UInt8]
            switch SpiceVMCMessage(rawValue: message.type) {
            case .data:
                bytes = message.payload
            case .compressedData:
                bytes = try decompress(message.payload)
            case nil:
                continue
            }
            let packets: [USBRedirIncoming]
            do {
                packets = try codec.feed(bytes)
            } catch {
                log.error("usbredir stream error on slot \(slot): \(error)")
                throw error
            }
            for packet in packets { await handle(packet) }
        }
    }

    public func close() async {
        closed = true
        expireHelloWaiters()
        await detachLocally(.channelClosed)
        await connection.close()
    }

    private func decompress(_ payload: [UInt8]) throws -> [UInt8] {
        var reader = ByteReader(payload)
        let type = try reader.readU8()
        guard type == DataCompressionType.lz4.rawValue else { return Array(reader.readRemaining()) }
        let size = Int(try reader.readU32())
        guard size <= Self.maxUncompressedSize else { throw WireError.limitExceeded("spicevmc \(size)") }
        return try LZ4Decoder.decompress(reader.readRemaining(), uncompressedSize: size)
    }

    private func sendRaw(_ bytes: [UInt8]) async throws {
        try await connection.send(SpiceMessage(type: SpiceVMCMessage.data.rawValue, payload: bytes))
    }

    private func send(_ bytes: [UInt8]) async {
        do {
            try await sendRaw(bytes)
        } catch {
            log.debug("usbredir send failed on slot \(slot): \(error)")
        }
    }

    // MARK: Attach / detach

    /// Exposes `newDevice` to the guest on this slot.
    ///
    /// Devices with a HID boot keyboard/mouse interface (including security keys such as
    /// YubiKeys, which type one-time passwords) are refused unless the user confirmed
    /// (`allowInputDevice`), so a keyboard or mouse is never taken from the Mac by accident.
    public func attach(_ newDevice: any USBRedirDevice, allowInputDevice: Bool = false,
                       attachmentID: UUID = UUID()) async throws {
        try Task.checkCancellation()
        // Reserve the slot before the first suspension point (actor reentrancy): a second
        // attach sees it busy, and close() during the awaits is detected afterwards.
        guard device == nil, !attaching, !detaching, !closed else { throw USBAttachError.slotBusy }
        attaching = true
        defer { attaching = false }
        if !guestHelloReceived {
            // The guest side (QEMU usb-redir) greets us when the slot opens; don't wait forever.
            let waiterID = UUID()
            helloWaiterID = waiterID
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.expireHelloWaiters(ifID: waiterID)
            }
            let ready = await withCheckedContinuation { helloWaiters.append($0) }
            timeout.cancel()
            guard ready else { throw USBAttachError.guestNotReady }
        }
        try Task.checkCancellation()
        let description = await newDevice.describe()
        try Task.checkCancellation()
        if description.isBootKeyboardOrMouse, !allowInputDevice { throw USBAttachError.keyboardOrMouse }
        if let guestFilter, !guestFilter.allows(description.filterDevice) { throw USBAttachError.rejectedByGuestFilter }
        guard !closed else { throw USBAttachError.guestNotReady }  // channel went away meanwhile
        device = newDevice
        self.attachmentID = attachmentID
        deviceName = newDevice.displayName
        rememberEndpoints(description)
        cancelledIDs.removeAll()
        // Order required by the protocol: ep_info, interface_info, then device_connect.
        do {
            try await sendRaw(codec.encodeEndpointInfo(description.endpoints))
            try checkAttachment(attachmentID)
            try await sendRaw(codec.encodeInterfaceInfo(description.interfaces))
            try checkAttachment(attachmentID)
            try await sendRaw(codec.encodeDeviceConnect(description))
            try checkAttachment(attachmentID)
        } catch {
            // A partial attach cannot be retried on the same wire stream safely.
            if self.attachmentID == attachmentID {
                closed = true
                await detachLocally(.channelClosed)
                await connection.close()
            }
            await waitForCleanup(attachmentID: attachmentID)
            throw error
        }
        events.yield(.attached(slot: slot, name: deviceName))
        log.info("slot \(slot): attached device (class \(description.deviceClass))")
    }

    /// Removes the device from the guest and releases it.
    public func detach() async {
        guard let attachmentID = attachmentID ?? cleanupID else { return }
        await detach(attachmentID: attachmentID)
    }

    /// Removes only this attachment; stale owners cannot detach a replacement device.
    public func detach(attachmentID: UUID) async {
        if let disconnectTask, disconnectTask.id == attachmentID {
            await disconnectTask.task.value
            return
        }
        if cleanupID == attachmentID {
            await withCheckedContinuation { cleanupWaiters.append($0) }
            return
        }
        guard self.attachmentID == attachmentID, device != nil else { return }
        let task = Task { await self.performDetach(attachmentID: attachmentID) }
        disconnectTask = (attachmentID, task)
        await task.value
        if disconnectTask?.id == attachmentID { disconnectTask = nil }
    }

    private func performDetach(attachmentID: UUID) async {
        do {
            try await sendRaw(codec.encodeDeviceDisconnect())
        } catch {
            closed = true
            await detachLocally(.channelClosed)
            await connection.close()
            return
        }
        guard self.attachmentID == attachmentID else {
            await waitForCleanup(attachmentID: attachmentID)
            return
        }
        if codec.negotiated(.deviceDisconnectAck) {
            // Wait (briefly) until the guest has stopped using the old device. The ack, the
            // timer, channel shutdown and detachLocally all resolve the same single waiter.
            let waiterID = UUID()
            let timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.resumeDisconnectAck(ifID: waiterID)
            }
            await waitForDisconnectAck(id: waiterID)
            timer.cancel()
            // While we waited the guest may have rejected it and another device been attached.
        }
        guard self.attachmentID == attachmentID else {
            await waitForCleanup(attachmentID: attachmentID)
            return
        }
        await detachLocally(.userRequest)
    }

    private func waitForCleanup(attachmentID: UUID) async {
        if cleanupID == attachmentID {
            await withCheckedContinuation { cleanupWaiters.append($0) }
        }
    }

    private func checkAttachment(_ id: UUID) throws {
        guard !closed, attachmentID == id, device != nil else { throw USBAttachError.guestNotReady }
    }

    private func expireHelloWaiters(ifID: UUID? = nil) {
        if let ifID, helloWaiterID != ifID { return }
        helloWaiterID = nil
        for waiter in helloWaiters { waiter.resume(returning: false) }
        helloWaiters.removeAll()
    }

    private func waitForDisconnectAck(id: UUID) async {
        await withCheckedContinuation { continuation in
            if device == nil || disconnectAckWaiter != nil {
                continuation.resume()  // nothing to wait for, or another detach is already waiting
            } else {
                disconnectAckID = id
                disconnectAckWaiter = continuation
            }
        }
    }

    private func resumeDisconnectAck(ifID: UUID? = nil) {
        if let ifID, disconnectAckID != ifID { return }
        disconnectAckWaiter?.resume()
        disconnectAckWaiter = nil
        disconnectAckID = nil
    }

    private func detachLocally(_ reason: USBDetachReason) async {
        guard let current = device, let attachmentID else {
            if cleanupID != nil { await withCheckedContinuation { cleanupWaiters.append($0) } }
            return
        }
        detaching = true
        cleanupID = attachmentID
        defer {
            detaching = false
            cleanupID = nil
            let waiters = cleanupWaiters
            cleanupWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        device = nil
        self.attachmentID = nil
        resumeDisconnectAck()
        endpointTypes.removeAll()
        outstandingBytes = 0
        let interruptEndpoints = Array(interruptPollers.keys)
        interruptPollers.removeAll()
        interruptPollerTokens.removeAll()
        for queue in endpointQueues.values { queue.finish() }
        endpointQueues.removeAll()
        // Finishing queues and retiring ownership stops future work. Cancelling a job
        // already sending a reply would cancel NetworkByteStream's reusable socket.
        queueTasks.removeAll()
        inFlight.removeAll()
        for endpoint in interruptEndpoints { await current.abort(endpoint: endpoint) }
        await current.close()
        events.yield(.detached(slot: slot, reason: reason))
        events.yield(.attachmentEnded(slot: slot, attachmentID: attachmentID, reason: reason))
        log.info("slot \(slot): detached (\(reason))")
    }

    // MARK: Packet handling

    private func handle(_ packet: USBRedirIncoming) async {
        let packetAttachmentID = attachmentID
        switch packet {
        case .hello(let version, _):
            log.sensitive("slot \(slot): guest hello", ChannelLogger.sanitize(version, limit: 64))
            guestHelloReceived = true
            helloWaiterID = nil
            for waiter in helloWaiters { waiter.resume(returning: true) }
            helloWaiters.removeAll()
        case .filterFilter(let text):
            guestFilter = try? USBFilter(parsing: text)
        case .filterReject:
            guard let packetAttachmentID else { return }
            await send(codec.encodeDeviceDisconnect())
            guard attachmentID == packetAttachmentID else { return }
            await detachLocally(.guestRejected)
        case .deviceDisconnectAck:
            resumeDisconnectAck()
        case .reset:
            guard let device else { return }
            if !(await device.reset()) {
                guard attachmentID == packetAttachmentID, self.device === device else { return }
                await send(codec.encodeDeviceDisconnect())
                guard attachmentID == packetAttachmentID else { return }
                await detachLocally(.deviceGone)
            }
        case .setConfiguration(let id, let value):
            guard let device else { return await send(codec.encodeConfigurationStatus(id: id, status: .ioerror, configuration: 0)) }
            let status = await device.setConfiguration(value)
            guard attachmentID == packetAttachmentID, self.device === device else { return }
            if status == .success { await sendDescriptionUpdate(device) }
            let configuration = await device.configuration()
            guard attachmentID == packetAttachmentID, self.device === device else { return }
            await send(codec.encodeConfigurationStatus(id: id, status: status, configuration: configuration))
        case .getConfiguration(let id):
            guard let device else { return await send(codec.encodeConfigurationStatus(id: id, status: .ioerror, configuration: 0)) }
            let configuration = await device.configuration()
            guard attachmentID == packetAttachmentID, self.device === device else { return }
            await send(codec.encodeConfigurationStatus(id: id, status: .success, configuration: configuration))
        case .setAltSetting(let id, let interface, let alt):
            guard let device else { return await send(codec.encodeAltSettingStatus(id: id, status: .ioerror, interface: interface, alt: 0)) }
            let status = await device.setAltSetting(interface: interface, alt: alt)
            guard attachmentID == packetAttachmentID, self.device === device else { return }
            if status == .success { await sendDescriptionUpdate(device) }
            let current = await device.altSetting(interface: interface) ?? 0
            guard attachmentID == packetAttachmentID, self.device === device else { return }
            await send(codec.encodeAltSettingStatus(id: id, status: status, interface: interface, alt: current))
        case .getAltSetting(let id, let interface):
            guard let device else { return }
            let value = await device.altSetting(interface: interface)
            guard attachmentID == packetAttachmentID, self.device === device else { return }
            guard let alt = value else {
                return await send(codec.encodeAltSettingStatus(id: id, status: .inval, interface: interface, alt: 0))
            }
            await send(codec.encodeAltSettingStatus(id: id, status: .success, interface: interface, alt: alt))
        case .startIsoStream(let id, let endpoint), .stopIsoStream(let id, let endpoint):
            // Isochronous transfers are not supported in v1 (AGENTS.md §7a).
            await send(codec.encodeIsoStreamStatus(id: id, status: .inval, endpoint: endpoint))
        case .startInterruptReceiving(let id, let endpoint):
            await startInterruptReceiving(id: id, endpoint: endpoint)
        case .stopInterruptReceiving(let id, let endpoint):
            // Retire the poller without cancelling a possible in-progress wire send.
            interruptPollers[endpoint] = nil
            interruptPollerTokens[endpoint] = nil
            if let device { await device.abort(endpoint: endpoint) }
            guard attachmentID == packetAttachmentID else { return }
            await send(codec.encodeInterruptReceivingStatus(id: id, status: .success, endpoint: endpoint))
        case .allocBulkStreams(let id, let endpoints, _), .freeBulkStreams(let id, let endpoints):
            await send(codec.encodeBulkStreamsStatus(id: id, status: .inval, endpoints: endpoints, streams: 0))
        case .startBulkReceiving(let id, let endpoint, let stream), .stopBulkReceiving(let id, let endpoint, let stream):
            await send(codec.encodeBulkReceivingStatus(id: id, status: .inval, endpoint: endpoint, streamID: stream))
        case .cancelDataPacket(let id):
            // Only ids that are actually in flight (the guest can't grow this set at will).
            if let entry = inFlight[id] {
                cancelledIDs.insert(id)
                if let device { await device.abort(endpoint: entry.endpoint) }
            }
        case .control(let id, let endpoint, let setup, let data):
            let bytes = Int(setup.length) + data.count
            guard device != nil, reserve(bytes, id: id) else {
                return await send(codec.encodeControlReply(id: id, endpoint: endpoint, setup: setup, status: .inval,
                                                           actualLength: 0, data: []))
            }
            enqueue(endpoint: 0, id: id, bytes: bytes) { channel, device, attachmentID in
                let result = await device.control(setup: setup, data: data)
                await channel.complete(id: id, attachmentID: attachmentID) { codec, status in
                    codec.encodeControlReply(id: id, endpoint: endpoint, setup: setup, status: status ?? result.status,
                                             actualLength: status == nil ? result.actualLength : 0, data: result.data)
                }
            }
        case .bulk(let id, let header, let data):
            let isIn = header.endpoint & 0x80 != 0
            // The declared IN length is guest-controlled: validate before anything is allocated.
            let bytes = isIn ? Int(header.length) : data.count
            guard endpointTypes[header.endpoint] == .bulk, reserve(bytes, id: id) else {
                return await send(codec.encodeBulkReply(id: id, endpoint: header.endpoint, streamID: header.streamID,
                                                        status: .inval, actualLength: 0, data: []))
            }
            enqueue(endpoint: header.endpoint, id: id, bytes: bytes) { channel, device, attachmentID in
                let result = await device.bulk(endpoint: header.endpoint, data: isIn ? [] : data,
                                               length: isIn ? Int(header.length) : data.count)
                await channel.complete(id: id, attachmentID: attachmentID) { codec, status in
                    codec.encodeBulkReply(id: id, endpoint: header.endpoint, streamID: header.streamID,
                                          status: status ?? result.status,
                                          actualLength: status == nil ? result.actualLength : 0, data: result.data)
                }
            }
        case .interrupt(let id, let header, let data):
            // Only interrupt OUT arrives as a packet; IN uses start_interrupt_receiving.
            guard header.endpoint & 0x80 == 0, endpointTypes[header.endpoint] == .interrupt, reserve(data.count, id: id) else {
                return await send(codec.encodeInterrupt(id: id, endpoint: header.endpoint, status: .inval,
                                                        actualLength: 0, data: []))
            }
            enqueue(endpoint: header.endpoint, id: id, bytes: data.count) { channel, device, attachmentID in
                let result = await device.interrupt(endpoint: header.endpoint, data: data, length: data.count)
                await channel.complete(id: id, attachmentID: attachmentID) { codec, status in
                    codec.encodeInterrupt(id: id, endpoint: header.endpoint, status: status ?? result.status,
                                          actualLength: status == nil ? result.actualLength : 0, data: [])
                }
            }
        case .iso:
            break  // not supported (start_iso_stream was refused)
        case .unknown(let type, _):
            log.debug("slot \(slot): ignoring usbredir packet type \(type)")
        }
    }

    private func sendDescriptionUpdate(_ device: any USBRedirDevice) async {
        let attachmentID = self.attachmentID
        let description = await device.describe()
        guard self.attachmentID == attachmentID, self.device === device else { return }
        rememberEndpoints(description)
        await send(codec.encodeEndpointInfo(description.endpoints))
        guard self.attachmentID == attachmentID, self.device === device else { return }
        await send(codec.encodeInterfaceInfo(description.interfaces))
    }

    private func rememberEndpoints(_ description: USBDeviceDescription) {
        endpointTypes = Dictionary(description.endpoints.map { ($0.address, $0.type) }, uniquingKeysWith: { first, _ in first })
    }

    /// Reserves budget for one transfer; `false` when it is too large or the slot is saturated.
    private func reserve(_ bytes: Int, id: UInt64) -> Bool {
        // A reused in-flight id would orphan the first reservation.
        guard inFlight[id] == nil, bytes >= 0, bytes <= USBTransferLimits.maxTransferLength,
              inFlight.count < USBTransferLimits.maxOutstandingPackets,
              outstandingBytes + bytes <= USBTransferLimits.maxOutstandingBytes else {
            log.info("slot \(slot): refused a \(bytes)-byte transfer (limits)")
            return false
        }
        outstandingBytes += bytes
        return true
    }

    /// Runs transfers for one endpoint strictly in order; endpoints run concurrently.
    private func enqueue(endpoint: UInt8, id: UInt64, bytes: Int,
                         _ work: @escaping @Sendable (USBRedirChannel, any USBRedirDevice, UUID) async -> Void) {
        guard let device, let attachmentID else {
            // No device: fail immediately with the matching packet type.
            outstandingBytes -= bytes
            failWithoutDevice(id: id)
            return
        }
        inFlight[id] = (endpoint, bytes)
        let queue: AsyncStream<@Sendable () async -> Void>.Continuation
        if let existing = endpointQueues[endpoint] {
            queue = existing
        } else {
            let (stream, continuation) = AsyncStream<@Sendable () async -> Void>.makeStream()
            endpointQueues[endpoint] = continuation
            queueTasks.append(Task { for await job in stream { await job() } })
            queue = continuation
        }
        queue.yield { [weak self] in
            guard let self else { return }
            guard await self.isCurrentAttachment(attachmentID) else { return }
            await work(self, device, attachmentID)
        }
    }

    private func failWithoutDevice(id: UInt64) {
        log.debug("slot \(slot): data packet \(id) without device")
    }

    /// Sends the reply for a finished data packet (as `.cancelled` if it was cancelled).
    private func complete(id: UInt64, attachmentID: UUID,
                          _ build: @Sendable (USBRedirCodec, USBRedirStatus?) -> [UInt8]) async {
        guard self.attachmentID == attachmentID else { return }
        if let entry = inFlight.removeValue(forKey: id) {
            outstandingBytes = max(0, outstandingBytes - entry.bytes)
        }
        guard device != nil else { return }
        let override: USBRedirStatus? = cancelledIDs.remove(id) != nil ? .cancelled : nil
        await send(build(codec, override))
    }

    private func isCurrentAttachment(_ id: UUID) -> Bool { attachmentID == id && device != nil }

    private func startInterruptReceiving(id: UInt64, endpoint: UInt8) async {
        let attachmentID = self.attachmentID
        guard let device, endpoint & 0x80 != 0, endpointTypes[endpoint] == .interrupt else {
            return await send(codec.encodeInterruptReceivingStatus(id: id, status: .inval, endpoint: endpoint))
        }
        // Idempotent: a repeated start must not stack pollers (each would leave a suspended
        // device request behind).
        guard interruptPollers[endpoint] == nil else {
            return await send(codec.encodeInterruptReceivingStatus(id: id, status: .success, endpoint: endpoint))
        }
        let description = await device.describe()
        let maxPacket = Int(description.endpoints.first { $0.address == endpoint }?.maxPacketSize ?? 64)
        guard interruptPollers[endpoint] == nil, self.attachmentID == attachmentID, self.device === device else {
            return await send(codec.encodeInterruptReceivingStatus(id: id, status: .success, endpoint: endpoint))
        }
        interruptPacketID[endpoint] = 0
        let token = UUID()
        interruptPollerTokens[endpoint] = token
        interruptPollers[endpoint] = Task { [weak self] in
            await self?.pollInterrupts(device: device, endpoint: endpoint, maxPacket: maxPacket, token: token)
        }
        await send(codec.encodeInterruptReceivingStatus(id: id, status: .success, endpoint: endpoint))
    }

    private func pollInterrupts(device: any USBRedirDevice, endpoint: UInt8, maxPacket: Int, token: UUID) async {
        defer { pollerFinished(endpoint: endpoint, token: token) }
        while !Task.isCancelled {
            let result = await device.interrupt(endpoint: endpoint, data: [], length: maxPacket)
            if Task.isCancelled || result.status == .cancelled { return }
            guard interruptPollerTokens[endpoint] == token else { return }
            await deliverInterrupt(endpoint: endpoint, result: result)
            if result.status != .success { return }
        }
    }

    /// A poller that stopped by itself frees its endpoint for a new start.
    private func pollerFinished(endpoint: UInt8, token: UUID) {
        guard interruptPollerTokens[endpoint] == token else { return }
        interruptPollerTokens[endpoint] = nil
        interruptPollers[endpoint] = nil
    }

    private func deliverInterrupt(endpoint: UInt8, result: USBTransferResult) async {
        guard device != nil else { return }
        let id = interruptPacketID[endpoint, default: 0]
        interruptPacketID[endpoint] = id &+ 1
        if result.status == .success {
            await send(codec.encodeInterrupt(id: id, endpoint: endpoint, status: .success,
                                             actualLength: result.data.count, data: result.data))
        } else {
            // A stopped stream is always reported as a stall (protocol §interrupt receiving).
            await send(codec.encodeInterruptReceivingStatus(id: 0, status: .stall, endpoint: endpoint))
        }
    }
}
