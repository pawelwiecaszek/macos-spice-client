import Testing
@testable import SpiceChannels
import SpiceTransport
import SpiceWire
@testable import USBRedirWire

/// A device with one bulk IN endpoint that records every bulk request it receives.
actor RecordingUSBDevice: USBRedirDevice {
    nonisolated let displayName = "Recorder"
    private(set) var bulkLengths: [Int] = []
    private(set) var closed = false

    func describe() async -> USBDeviceDescription {
        USBDeviceDescription(speed: .high, deviceClass: 0xFF, deviceSubclass: 0, deviceProtocol: 0,
                             vendorID: 0x1209, productID: 0x0001, deviceVersionBCD: 0x0100,
                             interfaces: [USBInterfaceInfo(number: 0, interfaceClass: 0xFF, interfaceSubclass: 0, interfaceProtocol: 0)],
                             endpoints: [USBEndpointInfo(address: 0x81, type: .bulk, interval: 0, interface: 0, maxPacketSize: 512)])
    }

    func control(setup: USBControlSetup, data: [UInt8]) async -> USBTransferResult { .failed(.stall) }
    func bulk(endpoint: UInt8, data: [UInt8], length: Int) async -> USBTransferResult {
        bulkLengths.append(length)
        return USBTransferResult(status: .success, data: [UInt8](repeating: 0xAB, count: min(length, 4)))
    }
    func interrupt(endpoint: UInt8, data: [UInt8], length: Int) async -> USBTransferResult { .failed(.stall) }
    func setConfiguration(_ value: UInt8) async -> USBRedirStatus { .success }
    func configuration() async -> UInt8 { 1 }
    func setAltSetting(interface: UInt8, alt: UInt8) async -> USBRedirStatus { .success }
    func altSetting(interface: UInt8) async -> UInt8? { 0 }
    func reset() async -> Bool { true }
    func abort(endpoint: UInt8) async {}
    func close() async { closed = true }
}

/// The guest (QEMU usb-redir) side of a usbredir slot.
struct GuestSide {
    let stream: MemoryByteStream
    let caps: USBRedirCapabilities
    private var pending: [UInt8] = []
    private var sawHostHello = false

    init(stream: MemoryByteStream, caps: USBRedirCapabilities) {
        self.stream = stream
        self.caps = caps
    }

    private func frame(_ type: USBRedirPacketType, id: UInt64, body: [UInt8], shortID: Bool) -> [UInt8] {
        var w = LEWriter()
        w.u32(type.rawValue)
        w.u32(UInt32(body.count))
        if shortID { w.u32(UInt32(id)) } else { w.u64(id) }
        w.bytes(body)
        return w.data
    }

    func sendSpiceVMC(_ usbredir: [UInt8]) async throws {
        try await stream.send(SpiceMessage(type: SpiceVMCMessage.data.rawValue, payload: usbredir).encode())
    }

    func sendHello() async throws {
        var w = LEWriter()
        w.bytes(Array("test guest".utf8) + [UInt8](repeating: 0, count: 64 - 10))
        for word in caps.words { w.u32(word) }
        try await sendSpiceVMC(frame(.hello, id: 0, body: w.data, shortID: true))
    }

    /// Bulk packet with a 32-bit length (requires `bulkLength32`).
    func sendBulk(id: UInt64, endpoint: UInt8, length: UInt32) async throws {
        var w = LEWriter()
        w.u8(endpoint); w.u8(0); w.u16(UInt16(truncatingIfNeeded: length)); w.u32(0)
        w.u16(UInt16(truncatingIfNeeded: length >> 16))
        try await sendSpiceVMC(frame(.bulkPacket, id: id, body: w.data, shortID: false))
    }

    /// Next packet from the client: (type, id, body).
    mutating func nextPacket() async throws -> (type: UInt32, id: UInt64, body: [UInt8]) {
        while true {
            let headerSize = sawHostHello ? 16 : 12
            if pending.count >= headerSize {
                var r = LEReader(pending)
                let type = r.u32()
                let length = Int(r.u32())
                let id = sawHostHello ? r.u64() : UInt64(r.u32())
                if pending.count >= headerSize + length {
                    let body = Array(pending[headerSize ..< headerSize + length])
                    pending.removeFirst(headerSize + length)
                    if type == USBRedirPacketType.hello.rawValue { sawHostHello = true }
                    return (type, id, body)
                }
            }
            var header = ByteReader(try await stream.receive(exactly: 6))
            _ = try header.readU16()
            let size = Int(try header.readU32())
            pending += try await stream.receive(exactly: size)
        }
    }
}

@Suite("usbredir channel limits")
struct USBRedirChannelTests {
    private func makeSlot(caps: USBRedirCapabilities) async throws
        -> (USBRedirChannel, GuestSide, RecordingUSBDevice, Task<Void, any Error>) {
        let (client, server) = await MemoryByteStream.pair()
        let connection = ChannelConnection(type: .usbredir, id: 0, stream: client, serverCaps: CapabilitySet(bits: []))
        let (_, sink) = AsyncStream<USBSlotEvent>.makeStream()
        let channel = USBRedirChannel(slot: 0, connection: connection, events: sink)
        let loop = Task { try await channel.run() }
        var guest = GuestSide(stream: server, caps: caps)
        #expect(try await guest.nextPacket().type == USBRedirPacketType.hello.rawValue)
        try await guest.sendHello()
        let device = RecordingUSBDevice()
        try await channel.attach(device)
        // ep_info, interface_info, device_connect
        for _ in 0 ..< 3 { _ = try await guest.nextPacket() }
        return (channel, guest, device, loop)
    }

    /// Audit finding 3: a tiny packet must not make the client allocate ~4 GiB.
    @Test func oversizedBulkInIsRefusedBeforeReachingTheDevice() async throws {
        let (channel, firstGuest, device, loop) = try await makeSlot(caps: USBRedirCapabilities([.ids64, .bulkLength32]))
        var guest = firstGuest
        try await guest.sendBulk(id: 7, endpoint: 0x81, length: 0xFFFF_FFFF)
        let reply = try await guest.nextPacket()
        #expect(reply.type == USBRedirPacketType.bulkPacket.rawValue)
        #expect(reply.id == 7)
        #expect(reply.body[1] == USBRedirStatus.inval.rawValue)

        // A request on an endpoint the device doesn't have is refused too.
        try await guest.sendBulk(id: 8, endpoint: 0x82, length: 64)
        #expect(try await guest.nextPacket().body[1] == USBRedirStatus.inval.rawValue)

        // A normal request still works.
        try await guest.sendBulk(id: 9, endpoint: 0x81, length: 512)
        let ok = try await guest.nextPacket()
        #expect(ok.id == 9)
        #expect(ok.body[1] == USBRedirStatus.success.rawValue)
        #expect(await device.bulkLengths == [512])
        loop.cancel()
        await channel.close()
    }

    /// Re-audit 5: a server that closes only the USB channel must not keep the device captured.
    @Test(.timeLimit(.minutes(1)))
    func channelLossReleasesTheDevice() async throws {
        let (channel, guest, device, loop) = try await makeSlot(caps: USBRedirCapabilities([.ids64]))
        await guest.stream.close()
        _ = try? await loop.value
        #expect(await device.closed)
        #expect(await channel.isFree == false)  // closed slots never accept a new device
        await #expect(throws: USBAttachError.slotBusy) { try await channel.attach(RecordingUSBDevice()) }
    }

    /// Re-audit 6: two overlapping attaches can't both take the slot.
    @Test(.timeLimit(.minutes(1)))
    func overlappingAttachesDontOverwrite() async throws {
        let (client, server) = await MemoryByteStream.pair()
        let connection = ChannelConnection(type: .usbredir, id: 0, stream: client, serverCaps: CapabilitySet(bits: []))
        let (_, sink) = AsyncStream<USBSlotEvent>.makeStream()
        let channel = USBRedirChannel(slot: 0, connection: connection, events: sink)
        let loop = Task { try await channel.run() }
        var guest = GuestSide(stream: server, caps: USBRedirCapabilities([.ids64]))
        _ = try await guest.nextPacket()
        // Both attaches wait for the guest hello; only one may win.
        let first = Task { try await channel.attach(RecordingUSBDevice()) }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task { try await channel.attach(RecordingUSBDevice()) }
        try await guest.sendHello()
        let results = [await first.result, await second.result]
        #expect(results.filter { if case .success = $0 { true } else { false } }.count == 1)
        loop.cancel()
        await channel.close()
    }

    /// Audit finding 6: a guest that never acknowledges the disconnect can't block detach.
    @Test(.timeLimit(.minutes(1)))
    func detachFinishesWhenTheAckIsWithheld() async throws {
        let (channel, _, _, loop) = try await makeSlot(caps: USBRedirCapabilities([.ids64, .deviceDisconnectAck]))
        let clock = ContinuousClock()
        let start = clock.now
        await channel.detach()
        #expect(clock.now - start < .seconds(5))
        #expect(await channel.isFree)
        loop.cancel()
        await channel.close()
    }
}
