import Foundation
import USBRedirWire

/// Random-access, read-only image storage (an `.iso` file, or memory in tests).
public protocol BlockSource: Sendable {
    var size: UInt64 { get }
    func read(offset: UInt64, count: Int) throws -> [UInt8]
}

/// An image file read with `pread` semantics through `FileHandle`.
public final class FileBlockSource: BlockSource, @unchecked Sendable {
    // FileHandle is only used under `lock`; size is immutable.
    private let handle: FileHandle
    private let lock = NSLock()
    public let size: UInt64

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    public func read(offset: UInt64, count: Int) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        try handle.seek(toOffset: offset)
        return Array(try handle.read(upToCount: count) ?? Data())
    }

    deinit { try? handle.close() }
}

/// In-memory image (tests).
public struct MemoryBlockSource: BlockSource {
    public let bytes: [UInt8]
    public var size: UInt64 { UInt64(bytes.count) }
    public init(bytes: [UInt8]) { self.bytes = bytes }
    public func read(offset: UInt64, count: Int) throws -> [UInt8] {
        let start = Int(min(offset, size))
        return Array(bytes[start..<min(bytes.count, start + count)])
    }
}

/// A virtual USB 2.0 CD/DVD drive (Mass Storage, Bulk-Only Transport, SCSI MMC) backed
/// by an image file. Exposed to the guest through a usbredir slot (AGENTS.md §7b).
public actor EmulatedCDROM: USBRedirDevice {
    public nonisolated let displayName: String
    private let source: any BlockSource
    private var scsi: SCSICDROM
    private var bot = BulkOnlyTransport()
    private var configured: UInt8 = 0
    /// Called when the guest ejects the medium (START STOP UNIT with LoEj).
    private let onEject: (@Sendable () -> Void)?

    public static let vendorID: UInt16 = 0x1209  // pid.codes open-source VID
    public static let productID: UInt16 = 0x0010  // TODO(verify): pid.codes test PID — register a real one before release
    static let bulkIn: UInt8 = 0x81
    static let bulkOut: UInt8 = 0x02
    static let maxPacket: UInt16 = 512

    public init(source: any BlockSource, name: String, onEject: (@Sendable () -> Void)? = nil) {
        self.source = source
        self.displayName = name
        self.scsi = SCSICDROM(blockCount: source.size / UInt64(SCSICDROM.blockSize))
        self.onEject = onEject
    }

    public init(url: URL, onEject: (@Sendable () -> Void)? = nil) throws {
        self.init(source: try FileBlockSource(url: url), name: url.lastPathComponent, onEject: onEject)
    }

    // MARK: USBRedirDevice

    public func describe() -> USBDeviceDescription {
        USBDeviceDescription(
            speed: .high, deviceClass: 0, deviceSubclass: 0, deviceProtocol: 0,
            vendorID: Self.vendorID, productID: Self.productID, deviceVersionBCD: 0x0100,
            interfaces: [USBInterfaceInfo(number: 0, interfaceClass: 0x08, interfaceSubclass: 0x06, interfaceProtocol: 0x50)],
            endpoints: [
                USBEndpointInfo(address: Self.bulkIn, type: .bulk, interval: 0, interface: 0, maxPacketSize: Self.maxPacket),
                USBEndpointInfo(address: Self.bulkOut, type: .bulk, interval: 0, interface: 0, maxPacketSize: Self.maxPacket),
            ])
    }

    public func control(setup: USBControlSetup, data: [UInt8]) -> USBTransferResult {
        let recipient = setup.requestType & 0x1F
        let kind = (setup.requestType >> 5) & 0x03
        switch (kind, setup.request) {
        case (0, 0x06):  // GET_DESCRIPTOR
            guard let descriptor = Descriptors.descriptor(type: UInt8(setup.value >> 8), index: UInt8(setup.value & 0xFF)) else {
                return .failed(.stall)
            }
            return USBTransferResult(status: .success, data: Array(descriptor.prefix(Int(setup.length))))
        case (0, 0x00):  // GET_STATUS
            return USBTransferResult(status: .success, data: [0, 0].prefix(Int(setup.length)).map { $0 })
        case (0, 0x01), (0, 0x03):  // CLEAR_FEATURE / SET_FEATURE (e.g. ENDPOINT_HALT)
            if recipient == 2 { bot.clearHalt() }
            return USBTransferResult(status: .success)
        case (0, 0x08):  // GET_CONFIGURATION
            return USBTransferResult(status: .success, data: [configured])
        case (0, 0x09):  // SET_CONFIGURATION
            configured = UInt8(setup.value & 0xFF)
            return USBTransferResult(status: .success)
        case (0, 0x0A):  // GET_INTERFACE
            return USBTransferResult(status: .success, data: [0])
        case (0, 0x0B):  // SET_INTERFACE
            return setup.value == 0 ? USBTransferResult(status: .success) : .failed(.stall)
        case (1, 0xFE):  // Get Max LUN
            return USBTransferResult(status: .success, data: [0])
        case (1, 0xFF):  // Bulk-Only Mass Storage Reset
            bot = BulkOnlyTransport()
            return USBTransferResult(status: .success)
        default:
            return .failed(.stall)
        }
    }

    public func bulk(endpoint: UInt8, data: [UInt8], length: Int) -> USBTransferResult {
        switch endpoint {
        case Self.bulkOut:
            return bot.handleOut(data, scsi: &scsi, source: source, onEject: onEject)
        case Self.bulkIn:
            return bot.handleIn(maxLength: length, scsi: &scsi, source: source)
        default:
            return .failed(.inval)
        }
    }

    public func interrupt(endpoint: UInt8, data: [UInt8], length: Int) -> USBTransferResult { .failed(.inval) }

    public func setConfiguration(_ value: UInt8) -> USBRedirStatus {
        guard value <= 1 else { return .stall }
        configured = value
        return .success
    }

    public func configuration() -> UInt8 { configured }

    public func setAltSetting(interface: UInt8, alt: UInt8) -> USBRedirStatus {
        interface == 0 && alt == 0 ? .success : .stall
    }

    public func altSetting(interface: UInt8) -> UInt8? { interface == 0 ? 0 : nil }

    public func reset() -> Bool {
        bot = BulkOnlyTransport()
        return true
    }

    public func abort(endpoint: UInt8) {}
    public func close() {}
}

// MARK: - Descriptors

enum Descriptors {
    static let device: [UInt8] = [
        18, 0x01, 0x00, 0x02,  // bLength, DEVICE, bcdUSB 2.00
        0x00, 0x00, 0x00, 64,  // class/subclass/protocol per interface, bMaxPacketSize0
        UInt8(EmulatedCDROM.vendorID & 0xFF), UInt8(EmulatedCDROM.vendorID >> 8),
        UInt8(EmulatedCDROM.productID & 0xFF), UInt8(EmulatedCDROM.productID >> 8),
        0x00, 0x01,  // bcdDevice 1.00
        1, 2, 3, 1,  // iManufacturer, iProduct, iSerialNumber, bNumConfigurations
    ]

    static func configuration(maxPacket: UInt16) -> [UInt8] {
        [
            9, 0x02, 32, 0, 1, 1, 0, 0x80, 50,  // config: total 32, 1 interface, bus powered, 100 mA
            9, 0x04, 0, 0, 2, 0x08, 0x06, 0x50, 0,  // interface: MSC, SCSI transparent, BOT
            7, 0x05, EmulatedCDROM.bulkIn, 0x02, UInt8(maxPacket & 0xFF), UInt8(maxPacket >> 8), 0,
            7, 0x05, EmulatedCDROM.bulkOut, 0x02, UInt8(maxPacket & 0xFF), UInt8(maxPacket >> 8), 0,
        ]
    }

    static let qualifier: [UInt8] = [10, 0x06, 0x00, 0x02, 0, 0, 0, 64, 1, 0]

    static func string(_ text: String) -> [UInt8] {
        let units = Array(text.utf16)
        var bytes: [UInt8] = [UInt8(2 + units.count * 2), 0x03]
        for unit in units { bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        return bytes
    }

    static func descriptor(type: UInt8, index: UInt8) -> [UInt8]? {
        switch type {
        case 0x01: return device
        case 0x02: return configuration(maxPacket: 512)
        case 0x07:  // other-speed configuration (full speed: 64-byte bulk packets)
            var other = configuration(maxPacket: 64)
            other[1] = 0x07
            return other
        case 0x06: return qualifier
        case 0x03:
            switch index {
            case 0: return [4, 0x03, 0x09, 0x04]  // English (US)
            case 1: return string("MacOS Spice Client")
            case 2: return string("Virtual CD-ROM")
            case 3: return string("5350494345303031")  // ≥ 12 hex digits, as MSC requires
            default: return nil
            }
        default:
            return nil
        }
    }
}
