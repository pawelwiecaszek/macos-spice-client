/// Errors decoding the usbredir byte stream.
public enum USBRedirError: Error, Equatable, Sendable {
    case malformed(String)
    case packetTooLarge(UInt32)
}

/// Bulk / interrupt / iso data packet header (unified view).
public struct USBDataHeader: Sendable, Hashable {
    public var endpoint: UInt8
    public var status: USBRedirStatus
    public var length: UInt32
    public var streamID: UInt32

    public init(endpoint: UInt8, status: USBRedirStatus = .success, length: UInt32, streamID: UInt32 = 0) {
        self.endpoint = endpoint
        self.status = status
        self.length = length
        self.streamID = streamID
    }
}

/// A packet received from the usb-guest.
public enum USBRedirIncoming: Sendable, Equatable {
    case hello(version: String, capabilities: USBRedirCapabilities)
    case reset
    case setConfiguration(id: UInt64, configuration: UInt8)
    case getConfiguration(id: UInt64)
    case setAltSetting(id: UInt64, interface: UInt8, alt: UInt8)
    case getAltSetting(id: UInt64, interface: UInt8)
    case startIsoStream(id: UInt64, endpoint: UInt8)
    case stopIsoStream(id: UInt64, endpoint: UInt8)
    case startInterruptReceiving(id: UInt64, endpoint: UInt8)
    case stopInterruptReceiving(id: UInt64, endpoint: UInt8)
    case allocBulkStreams(id: UInt64, endpoints: UInt32, streams: UInt32)
    case freeBulkStreams(id: UInt64, endpoints: UInt32)
    case cancelDataPacket(id: UInt64)
    case filterReject
    case filterFilter(String)
    case deviceDisconnectAck
    case startBulkReceiving(id: UInt64, endpoint: UInt8, streamID: UInt32)
    case stopBulkReceiving(id: UInt64, endpoint: UInt8, streamID: UInt32)
    case control(id: UInt64, endpoint: UInt8, setup: USBControlSetup, data: [UInt8])
    case bulk(id: UInt64, header: USBDataHeader, data: [UInt8])
    case interrupt(id: UInt64, header: USBDataHeader, data: [UInt8])
    case iso(id: UInt64, header: USBDataHeader, data: [UInt8])
    case unknown(type: UInt32, id: UInt64)
}

/// Incremental usbredir parser + encoder for the **usb-host** side.
///
/// Feed raw stream bytes with `feed(_:)`; build replies with the `encode…` methods.
/// The id width (32/64 bit) and optional fields follow the negotiated capabilities.
public struct USBRedirCodec: Sendable {
    public let ourCapabilities: USBRedirCapabilities
    public private(set) var peerCapabilities: USBRedirCapabilities?
    private var buffer: [UInt8] = []
    private var readOffset = 0

    /// Packets larger than this are rejected (hostile-input bound).
    public static let maxPacketLength: UInt32 = 64 * 1024 * 1024

    public init(capabilities: USBRedirCapabilities = .client) {
        ourCapabilities = capabilities
    }

    /// `true` once both sides advertised `cap` (hello exchanged).
    public func negotiated(_ cap: USBRedirCapability) -> Bool {
        ourCapabilities.contains(cap) && (peerCapabilities?.contains(cap) ?? false)
    }

    private var idSize: Int { negotiated(.ids64) ? 8 : 4 }

    // MARK: Decoding

    public mutating func feed(_ bytes: [UInt8]) throws(USBRedirError) -> [USBRedirIncoming] {
        buffer.append(contentsOf: bytes)
        var packets: [USBRedirIncoming] = []
        while true {
            // Before the peer hello, ids are 32-bit (the hello itself always is).
            let headerSize = 8 + idSize
            guard buffer.count - readOffset >= headerSize else { break }
            var r = LEReader(buffer, offset: readOffset)
            let type = r.u32()
            let length = r.u32()
            let id = idSize == 8 ? r.u64() : UInt64(r.u32())
            guard length <= Self.maxPacketLength else { throw .packetTooLarge(length) }
            guard buffer.count - readOffset - headerSize >= Int(length) else { break }
            let bodyStart = readOffset + headerSize
            let body = Array(buffer[bodyStart..<(bodyStart + Int(length))])
            readOffset = bodyStart + Int(length)
            packets.append(try decode(type: type, id: id, body: body))
        }
        if readOffset > 0 && (readOffset == buffer.count || readOffset > 1 << 20) {
            buffer.removeFirst(readOffset)
            readOffset = 0
        }
        return packets
    }

    private mutating func decode(type rawType: UInt32, id: UInt64, body: [UInt8]) throws(USBRedirError) -> USBRedirIncoming {
        var r = LEReader(body)
        func need(_ count: Int) throws(USBRedirError) {
            guard body.count >= count else { throw .malformed("packet \(rawType) too short (\(body.count) < \(count))") }
        }
        guard let type = USBRedirPacketType(rawValue: rawType) else { return .unknown(type: rawType, id: id) }
        switch type {
        case .hello:
            try need(64)
            let versionBytes = body.prefix(64).prefix { $0 != 0 }
            r.skip(64)
            var words: [UInt32] = []
            while r.remaining >= 4 { words.append(r.u32()) }
            let caps = USBRedirCapabilities(words: words)
            peerCapabilities = caps
            return .hello(version: String(decoding: versionBytes, as: UTF8.self), capabilities: caps)
        case .reset:
            return .reset
        case .setConfiguration:
            try need(1)
            return .setConfiguration(id: id, configuration: r.u8())
        case .getConfiguration:
            return .getConfiguration(id: id)
        case .setAltSetting:
            try need(2)
            return .setAltSetting(id: id, interface: r.u8(), alt: r.u8())
        case .getAltSetting:
            try need(1)
            return .getAltSetting(id: id, interface: r.u8())
        case .startIsoStream:
            try need(3)
            return .startIsoStream(id: id, endpoint: r.u8())
        case .stopIsoStream:
            try need(1)
            return .stopIsoStream(id: id, endpoint: r.u8())
        case .startInterruptReceiving:
            try need(1)
            return .startInterruptReceiving(id: id, endpoint: r.u8())
        case .stopInterruptReceiving:
            try need(1)
            return .stopInterruptReceiving(id: id, endpoint: r.u8())
        case .allocBulkStreams:
            try need(8)
            return .allocBulkStreams(id: id, endpoints: r.u32(), streams: r.u32())
        case .freeBulkStreams:
            try need(4)
            return .freeBulkStreams(id: id, endpoints: r.u32())
        case .cancelDataPacket:
            return .cancelDataPacket(id: id)
        case .filterReject:
            return .filterReject
        case .filterFilter:
            return .filterFilter(String(decoding: body.prefix { $0 != 0 }, as: UTF8.self))
        case .deviceDisconnectAck:
            return .deviceDisconnectAck
        case .startBulkReceiving:
            try need(10)
            let stream = r.u32()
            _ = r.u32()  // bytes_per_transfer
            return .startBulkReceiving(id: id, endpoint: r.u8(), streamID: stream)
        case .stopBulkReceiving:
            try need(5)
            let stream = r.u32()
            return .stopBulkReceiving(id: id, endpoint: r.u8(), streamID: stream)
        case .controlPacket:
            try need(10)
            let endpoint = r.u8()
            let request = r.u8()
            let requestType = r.u8()
            _ = r.u8()  // status (host → guest only)
            let setup = USBControlSetup(requestType: requestType, request: request,
                                        value: r.u16(), index: r.u16(), length: r.u16())
            return .control(id: id, endpoint: endpoint, setup: setup, data: Array(body.dropFirst(10)))
        case .bulkPacket:
            let long = negotiated(.bulkLength32)
            let size = long ? 10 : 8
            try need(size)
            let endpoint = r.u8()
            let status = USBRedirStatus(rawValue: r.u8()) ?? .ioerror
            var length = UInt32(r.u16())
            let stream = r.u32()
            if long { length |= UInt32(r.u16()) << 16 }
            return .bulk(id: id, header: USBDataHeader(endpoint: endpoint, status: status, length: length, streamID: stream),
                         data: Array(body.dropFirst(size)))
        case .interruptPacket, .isoPacket:
            try need(4)
            let endpoint = r.u8()
            let status = USBRedirStatus(rawValue: r.u8()) ?? .ioerror
            let header = USBDataHeader(endpoint: endpoint, status: status, length: UInt32(r.u16()))
            let data = Array(body.dropFirst(4))
            return type == .isoPacket ? .iso(id: id, header: header, data: data) : .interrupt(id: id, header: header, data: data)
        default:
            // Host → guest packet types should never arrive here.
            return .unknown(type: rawType, id: id)
        }
    }

    // MARK: Encoding (usb-host → usb-guest)

    private func packet(_ type: USBRedirPacketType, id: UInt64 = 0, body: [UInt8], forceShortID: Bool = false) -> [UInt8] {
        var w = LEWriter()
        w.u32(type.rawValue)
        w.u32(UInt32(body.count))
        if idSize == 8 && !forceShortID { w.u64(id) } else { w.u32(UInt32(truncatingIfNeeded: id)) }
        w.bytes(body)
        return w.data
    }

    /// Our hello (always 32-bit id, sent before the peer's hello is known).
    public func encodeHello() -> [UInt8] {
        var w = LEWriter()
        var version = Array(usbRedirVersionString.utf8.prefix(63))
        version += [UInt8](repeating: 0, count: 64 - version.count)
        w.bytes(version)
        for word in ourCapabilities.words { w.u32(word) }
        return packet(.hello, body: w.data, forceShortID: true)
    }

    public func encodeDeviceConnect(_ device: USBDeviceDescription) -> [UInt8] {
        var w = LEWriter()
        w.u8(device.speed.rawValue)
        w.u8(device.deviceClass)
        w.u8(device.deviceSubclass)
        w.u8(device.deviceProtocol)
        w.u16(device.vendorID)
        w.u16(device.productID)
        if negotiated(.connectDeviceVersion) { w.u16(device.deviceVersionBCD) }
        return packet(.deviceConnect, body: w.data)
    }

    public func encodeDeviceDisconnect() -> [UInt8] { packet(.deviceDisconnect, body: []) }

    public func encodeInterfaceInfo(_ interfaces: [USBInterfaceInfo]) -> [UInt8] {
        let list = Array(interfaces.prefix(32))
        var w = LEWriter()
        w.u32(UInt32(list.count))
        for field in 0..<4 {
            for index in 0..<32 {
                guard index < list.count else { w.u8(0); continue }
                let interface = list[index]
                switch field {
                case 0: w.u8(interface.number)
                case 1: w.u8(interface.interfaceClass)
                case 2: w.u8(interface.interfaceSubclass)
                default: w.u8(interface.interfaceProtocol)
                }
            }
        }
        return packet(.interfaceInfo, body: w.data)
    }

    public func encodeEndpointInfo(_ endpoints: [USBEndpointInfo]) -> [UInt8] {
        var types = [UInt8](repeating: USBTransferType.invalid.rawValue, count: 32)
        var intervals = [UInt8](repeating: 0, count: 32)
        var interfaces = [UInt8](repeating: 0, count: 32)
        var maxPacket = [UInt16](repeating: 0, count: 32)
        // Endpoint 0 (control) in both directions.
        for index in [0, 16] {
            types[index] = USBTransferType.control.rawValue
            maxPacket[index] = 64
        }
        for endpoint in endpoints where endpoint.address & 0x0F != 0 {
            let index = endpoint.redirIndex
            types[index] = endpoint.type.rawValue
            intervals[index] = endpoint.interval
            interfaces[index] = endpoint.interface
            maxPacket[index] = endpoint.maxPacketSize
        }
        var w = LEWriter()
        w.bytes(types)
        w.bytes(intervals)
        w.bytes(interfaces)
        if negotiated(.epInfoMaxPacketSize) { for value in maxPacket { w.u16(value) } }
        if negotiated(.bulkStreams) { for _ in 0..<32 { w.u32(0) } }
        return packet(.epInfo, body: w.data)
    }

    public func encodeConfigurationStatus(id: UInt64, status: USBRedirStatus, configuration: UInt8) -> [UInt8] {
        packet(.configurationStatus, id: id, body: [status.rawValue, configuration])
    }

    public func encodeAltSettingStatus(id: UInt64, status: USBRedirStatus, interface: UInt8, alt: UInt8) -> [UInt8] {
        packet(.altSettingStatus, id: id, body: [status.rawValue, interface, alt])
    }

    public func encodeIsoStreamStatus(id: UInt64, status: USBRedirStatus, endpoint: UInt8) -> [UInt8] {
        packet(.isoStreamStatus, id: id, body: [status.rawValue, endpoint])
    }

    public func encodeInterruptReceivingStatus(id: UInt64, status: USBRedirStatus, endpoint: UInt8) -> [UInt8] {
        packet(.interruptReceivingStatus, id: id, body: [status.rawValue, endpoint])
    }

    public func encodeBulkStreamsStatus(id: UInt64, status: USBRedirStatus, endpoints: UInt32, streams: UInt32) -> [UInt8] {
        var w = LEWriter()
        w.u32(endpoints)
        w.u32(streams)
        w.u8(status.rawValue)
        return packet(.bulkStreamsStatus, id: id, body: w.data)
    }

    public func encodeBulkReceivingStatus(id: UInt64, status: USBRedirStatus, endpoint: UInt8, streamID: UInt32) -> [UInt8] {
        var w = LEWriter()
        w.u32(streamID)
        w.u8(endpoint)
        w.u8(status.rawValue)
        return packet(.bulkReceivingStatus, id: id, body: w.data)
    }

    /// Reply to a control packet. `data` is only included for IN transfers.
    public func encodeControlReply(id: UInt64, endpoint: UInt8, setup: USBControlSetup, status: USBRedirStatus,
                                   actualLength: Int, data: [UInt8]) -> [UInt8] {
        var w = LEWriter()
        w.u8(endpoint)
        w.u8(setup.request)
        w.u8(setup.requestType)
        w.u8(status.rawValue)
        w.u16(setup.value)
        w.u16(setup.index)
        w.u16(UInt16(clamping: actualLength))
        if setup.isDeviceToHost { w.bytes(data.prefix(actualLength)) }
        return packet(.controlPacket, id: id, body: w.data)
    }

    /// Reply to a bulk packet. `data` is only included for IN endpoints.
    public func encodeBulkReply(id: UInt64, endpoint: UInt8, streamID: UInt32, status: USBRedirStatus,
                                actualLength: Int, data: [UInt8]) -> [UInt8] {
        let long = negotiated(.bulkLength32)
        let length = UInt32(clamping: actualLength)
        var w = LEWriter()
        w.u8(endpoint)
        w.u8(status.rawValue)
        w.u16(UInt16(truncatingIfNeeded: length))
        w.u32(streamID)
        if long { w.u16(UInt16(truncatingIfNeeded: length >> 16)) }
        if endpoint & 0x80 != 0 { w.bytes(data.prefix(actualLength)) }
        return packet(.bulkPacket, id: id, body: w.data)
    }

    /// Interrupt packet: reply to an OUT transfer, or unsolicited IN data.
    public func encodeInterrupt(id: UInt64, endpoint: UInt8, status: USBRedirStatus,
                                actualLength: Int, data: [UInt8]) -> [UInt8] {
        var w = LEWriter()
        w.u8(endpoint)
        w.u8(status.rawValue)
        w.u16(UInt16(clamping: actualLength))
        if endpoint & 0x80 != 0 { w.bytes(data.prefix(actualLength)) }
        return packet(.interruptPacket, id: id, body: w.data)
    }

    public func encodeFilter(_ filter: String) -> [UInt8] {
        packet(.filterFilter, body: Array(filter.utf8) + [0])
    }
}

// MARK: - Little-endian helpers (bounds are checked by callers via `need`)

struct LEReader {
    let bytes: [UInt8]
    var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var remaining: Int { bytes.count - offset }

    mutating func skip(_ count: Int) { offset += count }

    mutating func u8() -> UInt8 {
        guard offset < bytes.count else { return 0 }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() -> UInt16 { UInt16(u8()) | UInt16(u8()) << 8 }
    mutating func u32() -> UInt32 { UInt32(u16()) | UInt32(u16()) << 16 }
    mutating func u64() -> UInt64 { UInt64(u32()) | UInt64(u32()) << 32 }
}

struct LEWriter {
    var data: [UInt8] = []
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(UInt8(truncatingIfNeeded: v)); data.append(UInt8(truncatingIfNeeded: v >> 8)) }
    mutating func u32(_ v: UInt32) { u16(UInt16(truncatingIfNeeded: v)); u16(UInt16(truncatingIfNeeded: v >> 16)) }
    mutating func u64(_ v: UInt64) { u32(UInt32(truncatingIfNeeded: v)); u32(UInt32(truncatingIfNeeded: v >> 32)) }
    mutating func bytes<C: Collection>(_ b: C) where C.Element == UInt8 { data.append(contentsOf: b) }
}
