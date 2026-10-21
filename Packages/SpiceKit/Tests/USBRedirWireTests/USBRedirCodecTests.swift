import Testing
@testable import USBRedirWire

/// Builds guest → host packets the way QEMU's usbredirparser frames them.
struct GuestEncoder {
    var ids64 = false
    var bulk32 = false

    func packet(_ type: USBRedirPacketType, id: UInt64 = 0, body: [UInt8], shortID: Bool = false) -> [UInt8] {
        var w = LEWriter()
        w.u32(type.rawValue)
        w.u32(UInt32(body.count))
        if ids64 && !shortID { w.u64(id) } else { w.u32(UInt32(id)) }
        w.bytes(body)
        return w.data
    }

    func hello(_ caps: USBRedirCapabilities) -> [UInt8] {
        var w = LEWriter()
        w.bytes(Array("qemu usb-redir guest".utf8) + [UInt8](repeating: 0, count: 64 - 20))
        for word in caps.words { w.u32(word) }
        return packet(.hello, body: w.data, shortID: true)
    }

    func control(id: UInt64, requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, length: UInt16, data: [UInt8] = []) -> [UInt8] {
        var w = LEWriter()
        w.u8(requestType & 0x80); w.u8(request); w.u8(requestType); w.u8(0)
        w.u16(value); w.u16(index); w.u16(length)
        w.bytes(data)
        return packet(.controlPacket, id: id, body: w.data)
    }

    func bulk(id: UInt64, endpoint: UInt8, length: UInt32, data: [UInt8] = []) -> [UInt8] {
        var w = LEWriter()
        w.u8(endpoint); w.u8(0); w.u16(UInt16(truncatingIfNeeded: length)); w.u32(0)
        if bulk32 { w.u16(UInt16(truncatingIfNeeded: length >> 16)) }
        w.bytes(data)
        return packet(.bulkPacket, id: id, body: w.data)
    }
}

@Suite("usbredir codec")
struct USBRedirCodecTests {
    @Test func helloNegotiationSwitchesTo64BitIDs() throws {
        var codec = USBRedirCodec()
        let hello = codec.encodeHello()
        var r = LEReader(hello)
        #expect(r.u32() == USBRedirPacketType.hello.rawValue)
        #expect(r.u32() == 64 + 4)
        #expect(r.u32() == 0)  // 32-bit id in the hello
        #expect(hello.count == 12 + 68)

        let guest = GuestEncoder(ids64: true, bulk32: true)
        let packets = try codec.feed(guest.hello(USBRedirCapabilities([.ids64, .bulkLength32, .connectDeviceVersion, .epInfoMaxPacketSize]))
                                     + guest.bulk(id: 0x1_0000_0001, endpoint: 0x81, length: 70_000))
        #expect(packets.count == 2)
        #expect(packets.first == .hello(version: "qemu usb-redir guest",
                                        capabilities: USBRedirCapabilities([.ids64, .bulkLength32, .connectDeviceVersion, .epInfoMaxPacketSize])))
        #expect(packets.last == .bulk(id: 0x1_0000_0001, header: USBDataHeader(endpoint: 0x81, length: 70_000), data: []))
        #expect(codec.negotiated(.ids64))
        #expect(!codec.negotiated(.filter))
    }

    @Test func partialFeedsAreBuffered() throws {
        var codec = USBRedirCodec()
        let guest = GuestEncoder()
        let bytes = guest.hello(USBRedirCapabilities([])) + guest.control(id: 7, requestType: 0x80, request: 6, value: 0x0100, index: 0, length: 18)
        var packets: [USBRedirIncoming] = []
        for byte in bytes { packets += try codec.feed([byte]) }
        #expect(packets.count == 2)
        #expect(packets.last == .control(id: 7, endpoint: 0x80,
                                         setup: USBControlSetup(requestType: 0x80, request: 6, value: 0x0100, index: 0, length: 18),
                                         data: []))
    }

    @Test func replyLayouts() throws {
        var codec = USBRedirCodec()
        _ = try codec.feed(GuestEncoder().hello(USBRedirCapabilities([.connectDeviceVersion, .epInfoMaxPacketSize])))
        let device = USBDeviceDescription(
            speed: .high, deviceClass: 0, deviceSubclass: 0, deviceProtocol: 0, vendorID: 0x1209, productID: 0x0010,
            deviceVersionBCD: 0x0100,
            interfaces: [USBInterfaceInfo(number: 0, interfaceClass: 8, interfaceSubclass: 6, interfaceProtocol: 0x50)],
            endpoints: [USBEndpointInfo(address: 0x81, type: .bulk, interval: 0, interface: 0, maxPacketSize: 512),
                        USBEndpointInfo(address: 0x02, type: .bulk, interval: 0, interface: 0, maxPacketSize: 512)])
        let connect = codec.encodeDeviceConnect(device)
        #expect(connect.count == 12 + 10, "device_version_bcd included when negotiated")
        let epInfo = codec.encodeEndpointInfo(device.endpoints)
        #expect(epInfo.count == 12 + 96 + 64, "max_packet_size included, no max_streams")
        #expect(epInfo[12 + 2] == USBTransferType.bulk.rawValue)  // OUT ep 2
        #expect(epInfo[12 + 17] == USBTransferType.bulk.rawValue)  // IN ep 1
        #expect(epInfo[12 + 0] == USBTransferType.control.rawValue)
        #expect(epInfo[12 + 1] == USBTransferType.invalid.rawValue)
        let interfaces = codec.encodeInterfaceInfo(device.interfaces)
        #expect(interfaces.count == 12 + 4 + 128)
        #expect(interfaces[12 + 4 + 32] == 8)  // interface_class[0]

        let reply = codec.encodeBulkReply(id: 3, endpoint: 0x81, streamID: 0, status: .success, actualLength: 4, data: [1, 2, 3, 4])
        #expect(reply.count == 12 + 8 + 4, "no length_high without 32bits_bulk_length")
        let outReply = codec.encodeBulkReply(id: 4, endpoint: 0x02, streamID: 0, status: .success, actualLength: 31, data: [])
        #expect(outReply.count == 12 + 8, "OUT replies carry no data")
    }

    @Test func rejectsHugePackets() throws {
        var codec = USBRedirCodec()
        var w = LEWriter()
        w.u32(USBRedirPacketType.bulkPacket.rawValue)
        w.u32(0xFFFF_FFFF)
        w.u32(1)
        #expect(throws: USBRedirError.packetTooLarge(0xFFFF_FFFF)) { try codec.feed(w.data) }
    }

    @Test func shortPacketsAreMalformedNotCrashes() throws {
        var codec = USBRedirCodec()
        _ = try codec.feed(GuestEncoder().hello(USBRedirCapabilities([])))
        let truncated = GuestEncoder().packet(.controlPacket, id: 1, body: [0x80, 6])
        #expect(throws: USBRedirError.self) { try codec.feed(truncated) }
    }

    @Test func fuzzNeverCrashes() {
        var state: UInt64 = 42
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return state >> 33
        }
        for _ in 0..<2000 {
            var codec = USBRedirCodec()
            let bytes = (0..<Int(next() % 120)).map { _ in UInt8(truncatingIfNeeded: next() % 7 == 0 ? next() : next() % 3) }
            _ = try? codec.feed(GuestEncoder().hello(USBRedirCapabilities([.ids64])) + bytes)
        }
    }
}
