import USBRedirWire

/// A smartcard as seen by the emulated reader (implemented with CryptoTokenKit on macOS).
public protocol CCIDCard: Sendable {
    var displayName: String { get }
    /// Opens an exclusive session and returns the ATR.
    func connect() async throws -> [UInt8]
    /// Sends one command APDU, returns the response APDU (data + SW1 SW2).
    func transmit(_ apdu: [UInt8]) async throws -> [UInt8]
    func disconnect() async
}

/// A virtual USB smartcard reader (USB CCID class 0x0B, Rev 1.10) exposed through a
/// usbredir slot. It works on any QEMU (e.g. stock Proxmox, which lacks the
/// `ccid-card-passthru` device) and uses the guest's built-in CCID class driver.
///
/// Short-APDU-level exchange: the guest sends whole command APDUs in `PC_to_RDR_XfrBlock`
/// and gets whole response APDUs back; T=0/T=1 framing is the card stack's business.
/// Written from the USB CCID 1.1 specification.
public actor EmulatedCCIDReader: USBRedirDevice {
    public nonisolated let displayName: String
    private let card: any CCIDCard

    public static let vendorID: UInt16 = 0x1209  // pid.codes open-source VID
    public static let productID: UInt16 = 0x0011  // TODO(verify): pid.codes test PID — register a real one before release
    static let bulkIn: UInt8 = 0x81
    static let bulkOut: UInt8 = 0x02
    static let interruptIn: UInt8 = 0x83
    static let maxPacket: UInt16 = 64
    /// dwMaxCCIDMessageLength: 10-byte header + 261-byte short APDU (Lc=255 + header + Le).
    static let maxMessageLength = 271
    /// Unread response bytes the reader holds before refusing new commands (a guest that
    /// sends commands without reading the answers must not grow memory).
    static let maxUnreadBytes = 4 * maxMessageLength
    /// Largest single OUT transfer accepted.
    static let maxOutTransfer = 4 * maxMessageLength

    private var configured: UInt8 = 0
    private var atr: [UInt8]?
    private var powered = false
    private var cardFailed = false

    /// Partial PC_to_RDR message being assembled from OUT transfers.
    private var outBuffer: [UInt8] = []
    /// Response bytes waiting for bulk IN transfers.
    private var inQueue: [UInt8] = []
    private var inWaiter: CheckedContinuation<Bool, Never>?
    /// NotifySlotChange still to be delivered on the interrupt endpoint.
    private var pendingNotification: [UInt8]? = [0x50, 0x03]  // card present + changed
    private var interruptWaiter: CheckedContinuation<Bool, Never>?
    private var closed = false

    public init(card: any CCIDCard) {
        self.card = card
        self.displayName = card.displayName
    }

    // MARK: USBRedirDevice

    public func describe() -> USBDeviceDescription {
        USBDeviceDescription(
            speed: .full, deviceClass: 0, deviceSubclass: 0, deviceProtocol: 0,
            vendorID: Self.vendorID, productID: Self.productID, deviceVersionBCD: 0x0100,
            interfaces: [USBInterfaceInfo(number: 0, interfaceClass: 0x0B, interfaceSubclass: 0, interfaceProtocol: 0)],
            endpoints: [
                USBEndpointInfo(address: Self.bulkOut, type: .bulk, interval: 0, interface: 0, maxPacketSize: Self.maxPacket),
                USBEndpointInfo(address: Self.bulkIn, type: .bulk, interval: 0, interface: 0, maxPacketSize: Self.maxPacket),
                USBEndpointInfo(address: Self.interruptIn, type: .interrupt, interval: 16, interface: 0, maxPacketSize: 8),
            ])
    }

    public func control(setup: USBControlSetup, data: [UInt8]) -> USBTransferResult {
        let kind = (setup.requestType >> 5) & 0x03
        switch (kind, setup.request) {
        case (0, 0x06):  // GET_DESCRIPTOR
            guard let descriptor = CCIDDescriptors.descriptor(type: UInt8(setup.value >> 8), index: UInt8(setup.value & 0xFF)) else {
                return .failed(.stall)
            }
            return USBTransferResult(status: .success, data: Array(descriptor.prefix(Int(setup.length))))
        case (0, 0x00):  // GET_STATUS
            return USBTransferResult(status: .success, data: Array([UInt8](repeating: 0, count: 2).prefix(Int(setup.length))))
        case (0, 0x01), (0, 0x03):  // CLEAR_FEATURE / SET_FEATURE
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
        case (1, 0x01):  // CCID ABORT
            return USBTransferResult(status: .success)
        case (1, 0x02), (1, 0x03):  // GET_CLOCK_FREQUENCIES / GET_DATA_RATES: none listed
            return USBTransferResult(status: .success, data: [])
        default:
            return .failed(.stall)
        }
    }

    public func bulk(endpoint: UInt8, data: [UInt8], length: Int) async -> USBTransferResult {
        switch endpoint {
        case Self.bulkOut:
            // Refuse (STALL) rather than queue: the guest must read answers first.
            guard data.count <= Self.maxOutTransfer, inQueue.count <= Self.maxUnreadBytes else {
                return .failed(.stall)
            }
            outBuffer += data
            await processOutBuffer()
            return USBTransferResult(status: .success, actualLength: data.count)
        case Self.bulkIn:
            while inQueue.isEmpty {
                guard !closed else { return .failed(.cancelled) }
                if !(await wait(for: Self.bulkIn)) { return .failed(.cancelled) }
            }
            let count = min(max(length, 0), inQueue.count)
            let chunk = Array(inQueue.prefix(count))
            inQueue.removeFirst(count)
            return USBTransferResult(status: .success, data: chunk)
        default:
            return .failed(.inval)
        }
    }

    public func interrupt(endpoint: UInt8, data: [UInt8], length: Int) async -> USBTransferResult {
        guard endpoint == Self.interruptIn else { return .failed(.inval) }
        while pendingNotification == nil {
            guard !closed else { return .failed(.cancelled) }
            if !(await wait(for: Self.interruptIn)) { return .failed(.cancelled) }
        }
        let message = pendingNotification ?? []
        pendingNotification = nil
        return USBTransferResult(status: .success, data: Array(message.prefix(max(length, 0))))
    }

    /// Suspends until woken (`true`) or aborted/cancelled (`false`). A newer wait on the same
    /// endpoint ends the older one, and task cancellation ends it too, so no suspended
    /// request is ever left behind.
    private func wait(for endpoint: UInt8) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if endpoint == Self.bulkIn {
                    inWaiter?.resume(returning: false)
                    inWaiter = continuation
                } else {
                    interruptWaiter?.resume(returning: false)
                    interruptWaiter = continuation
                }
                if Task.isCancelled { abort(endpoint: endpoint) }
            }
        } onCancel: {
            Task { await self.abort(endpoint: endpoint) }
        }
    }

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
        outBuffer.removeAll()
        inQueue.removeAll()
        powered = false
        return true
    }

    public func abort(endpoint: UInt8) {
        switch endpoint {
        case Self.bulkIn:
            inWaiter?.resume(returning: false)
            inWaiter = nil
        case Self.interruptIn:
            interruptWaiter?.resume(returning: false)
            interruptWaiter = nil
        default:
            break
        }
    }

    public func close() async {
        closed = true
        abort(endpoint: Self.bulkIn)
        abort(endpoint: Self.interruptIn)
        if atr != nil { await card.disconnect() }
        atr = nil
    }

    // MARK: CCID commands

    private func processOutBuffer() async {
        while outBuffer.count >= 10 {
            guard inQueue.count <= Self.maxUnreadBytes else {
                outBuffer.removeAll()  // more batched commands than answers we will hold
                return
            }
            let length = Int(outBuffer[1]) | Int(outBuffer[2]) << 8 | Int(outBuffer[3]) << 16 | Int(outBuffer[4]) << 24
            guard length <= Self.maxMessageLength - 10 else {
                // Malformed or oversized: answer this header and drop the stream.
                let header = Array(outBuffer.prefix(10))
                outBuffer.removeAll()
                respond(CCIDResponse.slotStatus(for: header, iccStatus: iccStatus, failed: true, error: 1))  // bad dwLength
                return
            }
            guard outBuffer.count >= 10 + length else { return }
            let message = Array(outBuffer.prefix(10 + length))
            outBuffer.removeFirst(10 + length)
            respond(await execute(message))
        }
    }

    private var iccStatus: UInt8 {
        if cardFailed { return 2 }  // no ICC present
        return powered ? 0 : 1      // present & active / present & inactive
    }

    private func execute(_ message: [UInt8]) async -> [UInt8] {
        let header = Array(message.prefix(10))
        let payload = Array(message.dropFirst(10))
        guard header[5] == 0 else {
            return CCIDResponse.slotStatus(for: header, iccStatus: iccStatus, failed: true, error: 5)  // bad slot
        }
        switch header[0] {
        case 0x62:  // PC_to_RDR_IccPowerOn
            do {
                if atr == nil { atr = try await card.connect() }
                powered = true
                cardFailed = false
                return CCIDResponse.dataBlock(for: header, iccStatus: 0, data: atr ?? [])
            } catch {
                cardFailed = true
                return CCIDResponse.dataBlock(for: header, iccStatus: 2, failed: true, error: 0xFE, data: [])  // ICC_MUTE
            }
        case 0x63:  // PC_to_RDR_IccPowerOff
            powered = false
            return CCIDResponse.slotStatus(for: header, iccStatus: iccStatus)
        case 0x65, 0x6E, 0x71, 0x72:  // GetSlotStatus, IccClock, Mechanical, Abort
            return CCIDResponse.slotStatus(for: header, iccStatus: iccStatus)
        case 0x6F:  // PC_to_RDR_XfrBlock
            guard powered, !payload.isEmpty else {
                return CCIDResponse.dataBlock(for: header, iccStatus: iccStatus, failed: true, error: 0xFE, data: [])
            }
            do {
                let response = try await card.transmit(payload)
                guard response.count <= Self.maxMessageLength - 10 else {
                    return CCIDResponse.dataBlock(for: header, iccStatus: iccStatus, failed: true, error: 0xFB, data: [])  // HW_ERROR
                }
                return CCIDResponse.dataBlock(for: header, iccStatus: 0, data: response)
            } catch {
                return CCIDResponse.dataBlock(for: header, iccStatus: iccStatus, failed: true, error: 0xFE, data: [])
            }
        case 0x6C, 0x61, 0x6D:  // GetParameters, SetParameters, ResetParameters
            return CCIDResponse.parameters(for: header, iccStatus: iccStatus, atr: atr ?? [])
        case 0x73:  // SetDataRateAndClockFrequency: report the defaults
            return CCIDResponse.dataRateAndClock(for: header, iccStatus: iccStatus)
        default:  // Escape, T0APDU, Secure, …: CMD_NOT_SUPPORTED
            return CCIDResponse.slotStatus(for: header, iccStatus: iccStatus, failed: true, error: 0)
        }
    }

    private func respond(_ bytes: [UInt8]) {
        inQueue += bytes
        inWaiter?.resume(returning: true)
        inWaiter = nil
    }
}

// MARK: - Messages

enum CCIDResponse {
    private static func message(_ type: UInt8, header: [UInt8], status: UInt8, error: UInt8, specific: UInt8,
                                data: [UInt8]) -> [UInt8] {
        let length = UInt32(data.count)
        return [type, UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), UInt8((length >> 16) & 0xFF), UInt8(length >> 24),
                header.count > 5 ? header[5] : 0, header.count > 6 ? header[6] : 0, status, error, specific] + data
    }

    private static func status(_ icc: UInt8, failed: Bool) -> UInt8 { (failed ? 0x40 : 0) | (icc & 0x03) }

    /// RDR_to_PC_DataBlock (0x80).
    static func dataBlock(for header: [UInt8], iccStatus: UInt8, failed: Bool = false, error: UInt8 = 0,
                          data: [UInt8]) -> [UInt8] {
        message(0x80, header: header, status: status(iccStatus, failed: failed), error: failed ? error : 0, specific: 0, data: data)
    }

    /// RDR_to_PC_SlotStatus (0x81); bClockStatus 0 = running.
    static func slotStatus(for header: [UInt8], iccStatus: UInt8, failed: Bool = false, error: UInt8 = 0) -> [UInt8] {
        message(0x81, header: header, status: status(iccStatus, failed: failed), error: failed ? error : 0, specific: 0, data: [])
    }

    /// RDR_to_PC_Parameters (0x82) for the protocol the ATR announces.
    static func parameters(for header: [UInt8], iccStatus: UInt8, atr: [UInt8]) -> [UInt8] {
        if ATR.protocols(atr).contains(1) {
            // T=1: Fi/Di 0x11, LRC, guard time 0, BWI 4 / CWI 13, clock stop off, IFSC 254, NAD 0.
            return message(0x82, header: header, status: status(iccStatus, failed: false), error: 0, specific: 1,
                           data: [0x11, 0x10, 0x00, 0x4D, 0x00, 0xFE, 0x00])
        }
        // T=0: Fi/Di 0x11, direct convention, guard time 0, WI 10, clock stop off.
        return message(0x82, header: header, status: status(iccStatus, failed: false), error: 0, specific: 0,
                       data: [0x11, 0x00, 0x00, 0x0A, 0x00])
    }

    /// RDR_to_PC_DataRateAndClockFrequency (0x84): 3.58 MHz, 9600 bps.
    static func dataRateAndClock(for header: [UInt8], iccStatus: UInt8) -> [UInt8] {
        message(0x84, header: header, status: status(iccStatus, failed: false), error: 0, specific: 0,
                data: le32(3580) + le32(9600))
    }

    static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }
}

enum ATR {
    /// Protocols announced in the ATR's TDi bytes (T=0 when none is given).
    static func protocols(_ atr: [UInt8]) -> Set<Int> {
        guard atr.count >= 2 else { return [0] }
        var result: Set<Int> = []
        var index = 1
        var y = atr[1] >> 4
        while index < atr.count {
            // Skip TAi, TBi, TCi; read TDi if present.
            for bit in [0x1, 0x2, 0x4] where y & UInt8(bit) != 0 { index += 1 }
            guard y & 0x8 != 0 else { break }
            index += 1
            guard index < atr.count else { break }
            let td = atr[index]
            result.insert(Int(td & 0x0F))
            y = td >> 4
        }
        return result.isEmpty ? [0] : result
    }
}

// MARK: - Descriptors

enum CCIDDescriptors {
    static let device: [UInt8] = [
        18, 0x01, 0x10, 0x01,  // bLength, DEVICE, bcdUSB 1.10 (full speed only)
        0x00, 0x00, 0x00, 64,  // class per interface, bMaxPacketSize0
        UInt8(EmulatedCCIDReader.vendorID & 0xFF), UInt8(EmulatedCCIDReader.vendorID >> 8),
        UInt8(EmulatedCCIDReader.productID & 0xFF), UInt8(EmulatedCCIDReader.productID >> 8),
        0x00, 0x01,  // bcdDevice 1.00
        1, 2, 3, 1,  // iManufacturer, iProduct, iSerialNumber, bNumConfigurations
    ]

    /// Smart Card Device Class descriptor (CCID 1.1 §5.1), 54 bytes.
    static let ccidClass: [UInt8] = {
        var d: [UInt8] = [54, 0x21, 0x10, 0x01]  // bLength, type, bcdCCID 1.10
        d.append(0x00)  // bMaxSlotIndex
        d.append(0x07)  // bVoltageSupport: 5 V, 3 V, 1.8 V
        d += CCIDResponse.le32(0x0000_0003)  // dwProtocols: T=0, T=1
        d += CCIDResponse.le32(3580)  // dwDefaultClock (kHz)
        d += CCIDResponse.le32(3580)  // dwMaximumClock
        d.append(0x00)  // bNumClockSupported
        d += CCIDResponse.le32(9600)  // dwDataRate (bps)
        d += CCIDResponse.le32(115_200)  // dwMaxDataRate
        d.append(0x00)  // bNumDataRatesSupported
        d += CCIDResponse.le32(254)  // dwMaxIFSD
        d += CCIDResponse.le32(0)  // dwSynchProtocols
        d += CCIDResponse.le32(0)  // dwMechanical
        // dwFeatures: automatic parameters from ATR, activation, voltage, clock, baud rate,
        // PPS and IFSD exchange; short APDU level exchange.
        d += CCIDResponse.le32(0x0002_04BE)
        d += CCIDResponse.le32(UInt32(EmulatedCCIDReader.maxMessageLength))  // dwMaxCCIDMessageLength
        d += [0xFF, 0xFF]  // bClassGetResponse / bClassEnvelope: echo the APDU's class
        d += [0x00, 0x00]  // wLcdLayout: none
        d.append(0x00)  // bPINSupport: none
        d.append(0x01)  // bMaxCCIDBusySlots
        return d
    }()

    static var configuration: [UInt8] {
        let interface: [UInt8] = [9, 0x04, 0, 0, 3, 0x0B, 0x00, 0x00, 0]  // CCID, 3 endpoints
        let endpoints: [UInt8] = [
            7, 0x05, EmulatedCCIDReader.bulkOut, 0x02, 64, 0, 0,
            7, 0x05, EmulatedCCIDReader.bulkIn, 0x02, 64, 0, 0,
            7, 0x05, EmulatedCCIDReader.interruptIn, 0x03, 8, 0, 16,
        ]
        let total = 9 + interface.count + ccidClass.count + endpoints.count
        let header: [UInt8] = [9, 0x02, UInt8(total & 0xFF), UInt8(total >> 8), 1, 1, 0, 0x80, 50]  // bus powered, 100 mA
        return header + interface + ccidClass + endpoints
    }

    static func descriptor(type: UInt8, index: UInt8) -> [UInt8]? {
        switch type {
        case 0x01: return device
        case 0x02: return configuration
        case 0x03:
            switch index {
            case 0: return [4, 0x03, 0x09, 0x04]  // English (US)
            case 1: return Descriptors.string("MacOS Spice Client")
            case 2: return Descriptors.string("Virtual Smart Card Reader")
            case 3: return Descriptors.string("5350494345434344")
            default: return nil
            }
        default:
            return nil  // full-speed only: no device qualifier
        }
    }
}
