// usbredir protocol 0.7 — constants and packet layouts.
// Source: usbredir/docs/usb-redirection-protocol.md (protocol description). All integers
// are little-endian, all structs packed. This client is the *usb-host*; QEMU's usb-redir
// device is the *usb-guest*.

/// Version string sent in our hello (free-form, for logging only).
public let usbRedirVersionString = "MacOS Spice Client"

/// `usb_redir_*` packet types.
public enum USBRedirPacketType: UInt32, Sendable {
    // Control packets
    case hello = 0
    case deviceConnect
    case deviceDisconnect
    case reset
    case interfaceInfo
    case epInfo
    case setConfiguration
    case getConfiguration
    case configurationStatus
    case setAltSetting
    case getAltSetting
    case altSettingStatus
    case startIsoStream
    case stopIsoStream
    case isoStreamStatus
    case startInterruptReceiving
    case stopInterruptReceiving
    case interruptReceivingStatus
    case allocBulkStreams
    case freeBulkStreams
    case bulkStreamsStatus
    case cancelDataPacket
    case filterReject
    case filterFilter
    case deviceDisconnectAck
    case startBulkReceiving
    case stopBulkReceiving
    case bulkReceivingStatus
    // Data packets
    case controlPacket = 100
    case bulkPacket
    case isoPacket
    case interruptPacket
    case bufferedBulkPacket
}

/// `usb_redir_success` … `usb_redir_babble`.
public enum USBRedirStatus: UInt8, Sendable {
    case success = 0
    case cancelled
    case inval
    case ioerror
    case stall
    case timeout
    case babble
}

/// `usb_redir_cap_*` bit indices.
public enum USBRedirCapability: Int, Sendable, CaseIterable {
    case bulkStreams = 0
    case connectDeviceVersion
    case filter
    case deviceDisconnectAck
    case epInfoMaxPacketSize
    case ids64
    case bulkLength32
    case bulkReceiving
}

/// `usb_redir_speed_*`.
public enum USBSpeed: UInt8, Sendable {
    case low = 0, full, high, `super`
    case unknown = 255
}

/// `usb_redir_type_*` (matches USB endpoint transfer types).
/// Resource limits for guest-requested transfers (the guest controls declared lengths).
public enum USBTransferLimits {
    /// Largest single bulk/interrupt/control transfer accepted (bytes).
    public static let maxTransferLength = 4 * 1024 * 1024
    /// Upper bound for bytes reserved by all queued and running transfers of one slot.
    public static let maxOutstandingBytes = 32 * 1024 * 1024
    /// Upper bound for queued and running transfers of one slot.
    public static let maxOutstandingPackets = 1024
}

public enum USBTransferType: UInt8, Sendable {
    case control = 0, iso, bulk, interrupt
    case invalid = 255
}

/// Capabilities as a bitmask over 32-bit words.
public struct USBRedirCapabilities: Sendable, Hashable {
    public private(set) var words: [UInt32]

    public init(words: [UInt32] = [0]) { self.words = words.isEmpty ? [0] : words }

    public init(_ caps: [USBRedirCapability]) {
        words = [0]
        for cap in caps { words[0] |= 1 << UInt32(cap.rawValue) }
    }

    public func contains(_ cap: USBRedirCapability) -> Bool {
        let word = cap.rawValue / 32
        return word < words.count && words[word] & (1 << UInt32(cap.rawValue % 32)) != 0
    }

    /// Capabilities the client (usb-host) advertises.
    public static let client = USBRedirCapabilities([
        .connectDeviceVersion, .filter, .deviceDisconnectAck, .epInfoMaxPacketSize, .ids64, .bulkLength32,
    ])
}

/// A USB control-transfer setup packet.
public struct USBControlSetup: Sendable, Hashable {
    public var requestType: UInt8
    public var request: UInt8
    public var value: UInt16
    public var index: UInt16
    public var length: UInt16

    public init(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, length: UInt16) {
        self.requestType = requestType
        self.request = request
        self.value = value
        self.index = index
        self.length = length
    }

    public var isDeviceToHost: Bool { requestType & 0x80 != 0 }
}

/// An interface of the active configuration.
public struct USBInterfaceInfo: Sendable, Hashable {
    public var number: UInt8
    public var interfaceClass: UInt8
    public var interfaceSubclass: UInt8
    public var interfaceProtocol: UInt8

    public init(number: UInt8, interfaceClass: UInt8, interfaceSubclass: UInt8, interfaceProtocol: UInt8) {
        self.number = number
        self.interfaceClass = interfaceClass
        self.interfaceSubclass = interfaceSubclass
        self.interfaceProtocol = interfaceProtocol
    }
}

/// An endpoint of the active configuration / alt settings.
public struct USBEndpointInfo: Sendable, Hashable {
    /// Endpoint address including the direction bit (0x80 = IN).
    public var address: UInt8
    public var type: USBTransferType
    public var interval: UInt8
    public var interface: UInt8
    public var maxPacketSize: UInt16

    public init(address: UInt8, type: USBTransferType, interval: UInt8, interface: UInt8, maxPacketSize: UInt16) {
        self.address = address
        self.type = type
        self.interval = interval
        self.interface = interface
        self.maxPacketSize = maxPacketSize
    }

    public var isIn: Bool { address & 0x80 != 0 }

    /// Index in `usb_redir_ep_info` arrays: 0–15 OUT, 16–31 IN.
    public var redirIndex: Int { Int(address & 0x0F) + (isIn ? 16 : 0) }
}

/// What `device_connect` + `interface_info` + `ep_info` describe.
public struct USBDeviceDescription: Sendable, Hashable {
    public var speed: USBSpeed
    public var deviceClass: UInt8
    public var deviceSubclass: UInt8
    public var deviceProtocol: UInt8
    public var vendorID: UInt16
    public var productID: UInt16
    public var deviceVersionBCD: UInt16
    public var interfaces: [USBInterfaceInfo]
    public var endpoints: [USBEndpointInfo]

    public init(speed: USBSpeed, deviceClass: UInt8, deviceSubclass: UInt8, deviceProtocol: UInt8,
                vendorID: UInt16, productID: UInt16, deviceVersionBCD: UInt16,
                interfaces: [USBInterfaceInfo], endpoints: [USBEndpointInfo]) {
        self.speed = speed
        self.deviceClass = deviceClass
        self.deviceSubclass = deviceSubclass
        self.deviceProtocol = deviceProtocol
        self.vendorID = vendorID
        self.productID = productID
        self.deviceVersionBCD = deviceVersionBCD
        self.interfaces = interfaces
        self.endpoints = endpoints
    }

    /// Filter view: device class plus every interface class.
    public var filterDevice: USBFilter.Device {
        USBFilter.Device(classes: Set([deviceClass] + interfaces.map(\.interfaceClass)),
                         vendorID: vendorID, productID: productID, deviceVersion: deviceVersionBCD)
    }

    /// HID boot keyboards / mice must never be redirected (they would take the Mac's input).
    public var isBootKeyboardOrMouse: Bool {
        interfaces.contains { $0.interfaceClass == 3 && $0.interfaceSubclass == 1 && ($0.interfaceProtocol == 1 || $0.interfaceProtocol == 2) }
    }
}
