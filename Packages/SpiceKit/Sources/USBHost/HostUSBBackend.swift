#if os(macOS) && canImport(IOUSBHost)
import Foundation
import IOKit
import IOKit.usb
import IOUSBHost
import USBRedirWire

/// Wraps a non-Sendable value whose access is serialized externally (actor or completion order).
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

/// A real USB device on the Mac exposed to the guest (AGENTS.md §7a), via IOUSBHost.
public actor HostUSBBackend: USBRedirDevice {
    public nonisolated let displayName: String
    public nonisolated let deviceID: UInt64
    private let device: IOUSBHostDevice
    private let ioQueue = DispatchQueue(label: "com.pawelwiecaszek.spiceclient.usb-io")
    private var interfaces: [UInt8: IOUSBHostInterface] = [:]
    private var altSettings: [UInt8: UInt8] = [:]
    private var pipes: [UInt8: IOUSBHostPipe] = [:]
    private var currentConfiguration: UInt8 = 0
    private var closed = false

    /// Opens (and takes ownership of) the device with registry entry `info.id`.
    public init(_ info: HostUSBDevice) throws {
        guard let matching = IORegistryEntryIDMatching(info.id) else { throw HostUSBError.notFound }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { throw HostUSBError.notFound }
        defer { IOObjectRelease(service) }
        var opened: IOUSBHostDevice?
        // Plain open works for devices without a macOS driver; "seize" asks the current
        // kernel owner to let go. Capture needs com.apple.vm.device-access (not available).
        for options: IOUSBHostObjectInitOptions in [[], [.deviceSeize]] {
            if let device = try? IOUSBHostDevice(__ioService: service, options: options, queue: nil, interestHandler: nil) {
                opened = device
                break
            }
        }
        guard let opened else { throw HostUSBError.inUseByMacOS }
        device = opened
        displayName = info.name
        deviceID = info.id
        currentConfiguration = Self.activeConfigurationValue(opened)
    }

    private static func activeConfigurationValue(_ device: IOUSBHostDevice) -> UInt8 {
        device.configurationDescriptor?.pointee.bConfigurationValue ?? 0
    }

    // MARK: Description

    public func describe() -> USBDeviceDescription {
        let descriptor = device.deviceDescriptor?.pointee
        var interfacesInfo: [USBInterfaceInfo] = []
        var endpoints: [USBEndpointInfo] = []
        if let config = device.configurationDescriptor {
            let total = Int(config.pointee.wTotalLength)
            let bytes = UnsafeRawPointer(config).bindMemory(to: UInt8.self, capacity: total)
            var offset = 0
            var currentInterface: UInt8?
            var include = false
            while offset + 2 <= total {
                let length = Int(bytes[offset])
                guard length >= 2, offset + length <= total else { break }
                let type = bytes[offset + 1]
                if type == 0x04, length >= 9 {  // INTERFACE
                    let number = bytes[offset + 2], alt = bytes[offset + 3]
                    include = alt == (altSettings[number] ?? 0)
                    currentInterface = number
                    if include {
                        interfacesInfo.append(USBInterfaceInfo(number: number, interfaceClass: bytes[offset + 5],
                                                               interfaceSubclass: bytes[offset + 6],
                                                               interfaceProtocol: bytes[offset + 7]))
                    }
                } else if type == 0x05, length >= 7, include, let interface = currentInterface {  // ENDPOINT
                    let transfer = USBTransferType(rawValue: bytes[offset + 3] & 0x03) ?? .invalid
                    let maxPacket = UInt16(bytes[offset + 4]) | UInt16(bytes[offset + 5]) << 8
                    endpoints.append(USBEndpointInfo(address: bytes[offset + 2], type: transfer, interval: bytes[offset + 6],
                                                     interface: interface, maxPacketSize: maxPacket & 0x07FF))
                }
                offset += length
            }
        }
        return USBDeviceDescription(
            speed: Self.speed(of: device), deviceClass: descriptor?.bDeviceClass ?? 0,
            deviceSubclass: descriptor?.bDeviceSubClass ?? 0, deviceProtocol: descriptor?.bDeviceProtocol ?? 0,
            vendorID: descriptor?.idVendor ?? 0, productID: descriptor?.idProduct ?? 0,
            deviceVersionBCD: descriptor?.bcdDevice ?? 0, interfaces: interfacesInfo, endpoints: endpoints)
    }

    private static func speed(of device: IOUSBHostDevice) -> USBSpeed {
        // kUSBHostMatchingPropertySpeed: 0 low, 1 full, 2 high, 3+ super.
        let value = (IORegistryEntryCreateCFProperty(device.ioService, "USBSpeed" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.intValue
        switch value {
        case 0: return .low
        case 1: return .full
        case 2: return .high
        case .some(let speed) where speed >= 3: return .super
        default:
            // Fall back on bcdUSB.
            let bcd = device.deviceDescriptor?.pointee.bcdUSB ?? 0x0200
            return bcd >= 0x0300 ? .super : bcd >= 0x0200 ? .high : .full
        }
    }

    // MARK: Configuration

    public func configuration() -> UInt8 { currentConfiguration }

    public func setConfiguration(_ value: UInt8) -> USBRedirStatus {
        releaseInterfaces()
        do {
            // matchInterfaces: false keeps macOS drivers from grabbing the interfaces we need.
            try device.__configure(withValue: Int(value), matchInterfaces: false)
            currentConfiguration = value
            altSettings.removeAll()
            openInterfaces()
            return .success
        } catch {
            return .ioerror
        }
    }

    public func setAltSetting(interface: UInt8, alt: UInt8) -> USBRedirStatus {
        if interfaces.isEmpty { openInterfaces() }
        guard let host = interfaces[interface] else { return .inval }
        do {
            try host.selectAlternateSetting(Int(alt))
            altSettings[interface] = alt
            pipes.removeAll()  // pipes of the old alt setting are gone; re-copied on demand
            return .success
        } catch {
            return .ioerror
        }
    }

    public func altSetting(interface: UInt8) -> UInt8? {
        if interfaces.isEmpty { openInterfaces() }
        return interfaces[interface] == nil ? nil : (altSettings[interface] ?? 0)
    }

    private func openInterfaces() {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device.ioService, kIOServicePlane, &children) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(children) }
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            guard IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
                  let interface = try? IOUSBHostInterface(__ioService: child, options: [], queue: nil, interestHandler: nil)
            else { continue }
            interfaces[interface.interfaceDescriptor.pointee.bInterfaceNumber] = interface
        }
    }

    private func releaseInterfaces() {
        for pipe in pipes.values { try? pipe.__abort(with: .synchronous) }
        pipes.removeAll()
        for interface in interfaces.values { interface.destroy() }
        interfaces.removeAll()
    }

    private func pipe(for endpoint: UInt8) -> IOUSBHostPipe? {
        if let pipe = pipes[endpoint] { return pipe }
        if interfaces.isEmpty { openInterfaces() }
        for interface in interfaces.values {
            if let pipe = try? interface.copyPipe(withAddress: Int(endpoint)) {
                pipes[endpoint] = pipe
                return pipe
            }
        }
        return nil
    }

    // MARK: Transfers

    public func control(setup: USBControlSetup, data: [UInt8]) async -> USBTransferResult {
        // CLEAR_FEATURE(ENDPOINT_HALT) must go through the pipe so the host controller resets its state too.
        if setup.requestType == 0x02, setup.request == 0x01, setup.value == 0 {
            guard let pipe = pipe(for: UInt8(truncatingIfNeeded: setup.index)) else { return .failed(.inval) }
            do {
                try pipe.clearStall()
                return USBTransferResult(status: .success)
            } catch {
                return .failed(.ioerror)
            }
        }
        let request = IOUSBDeviceRequest(bmRequestType: setup.requestType, bRequest: setup.request,
                                         wValue: setup.value, wIndex: setup.index, wLength: setup.length)
        let buffer = NSMutableData(length: Int(setup.length)) ?? NSMutableData()
        if !setup.isDeviceToHost, !data.isEmpty {
            buffer.replaceBytes(in: NSRange(location: 0, length: min(data.count, buffer.length)), withBytes: data)
        }
        let box = UncheckedBox(value: (device, buffer))
        // Synchronous IOKit call on a private queue keeps the cooperative pool free.
        let outcome: (USBRedirStatus, Int) = await withCheckedContinuation { continuation in
            ioQueue.async {
                var transferred = 0
                do {
                    try box.value.0.__send(request, data: setup.length > 0 ? box.value.1 : nil,
                                           bytesTransferred: &transferred, completionTimeout: 5)
                    continuation.resume(returning: (.success, transferred))
                } catch {
                    continuation.resume(returning: (Self.status(for: error), 0))
                }
            }
        }
        guard outcome.0 == .success else { return .failed(outcome.0) }
        if setup.isDeviceToHost {
            let bytes = [UInt8](Data(referencing: buffer).prefix(outcome.1))
            return USBTransferResult(status: .success, data: bytes)
        }
        return USBTransferResult(status: .success, actualLength: outcome.1)
    }

    public func bulk(endpoint: UInt8, data: [UInt8], length: Int) async -> USBTransferResult {
        await transfer(endpoint: endpoint, data: data, length: length, timeout: 0)
    }

    public func interrupt(endpoint: UInt8, data: [UInt8], length: Int) async -> USBTransferResult {
        await transfer(endpoint: endpoint, data: data, length: length, timeout: 0)
    }

    private func transfer(endpoint: UInt8, data: [UInt8], length: Int, timeout: TimeInterval) async -> USBTransferResult {
        guard !closed, let pipe = pipe(for: endpoint) else { return .failed(.inval) }
        let isIn = endpoint & 0x80 != 0
        let capacity = isIn ? length : data.count
        // Defence in depth: the channel already bounds guest-declared lengths.
        guard capacity >= 0, capacity <= USBTransferLimits.maxTransferLength else { return .failed(.inval) }
        guard let buffer = try? device.ioData(withCapacity: max(capacity, 1)) else { return .failed(.ioerror) }
        buffer.length = capacity
        if !isIn, !data.isEmpty {
            buffer.replaceBytes(in: NSRange(location: 0, length: data.count), withBytes: data)
        }
        let box = UncheckedBox(value: (pipe, buffer))
        let outcome: (USBRedirStatus, Int) = await withCheckedContinuation { continuation in
            do {
                try box.value.0.enqueueIORequest(with: box.value.1, completionTimeout: timeout) { status, transferred in
                    continuation.resume(returning: (Self.status(for: status), transferred))
                }
            } catch {
                continuation.resume(returning: (Self.status(for: error), 0))
            }
        }
        guard outcome.0 == .success else { return .failed(outcome.0) }
        if isIn {
            return USBTransferResult(status: .success, data: [UInt8](Data(referencing: buffer).prefix(outcome.1)))
        }
        return USBTransferResult(status: .success, actualLength: outcome.1)
    }

    public func abort(endpoint: UInt8) {
        if endpoint & 0x7F == 0 {
            try? device.__abortDeviceRequests(with: .asynchronous)
        } else {
            try? pipes[endpoint]?.__abort(with: .asynchronous)
        }
    }

    public func reset() -> Bool {
        releaseInterfaces()
        do {
            try device.reset()
            return true
        } catch {
            return false
        }
    }

    public func close() {
        guard !closed else { return }
        closed = true
        releaseInterfaces()
        // destroy() resets the device and lets macOS drivers match again.
        device.destroy()
    }

    // MARK: Status mapping

    nonisolated static func status(for error: any Error) -> USBRedirStatus {
        let code = (error as NSError).code
        return status(for: IOReturn(truncatingIfNeeded: code))
    }

    nonisolated static func status(for value: IOReturn) -> USBRedirStatus {
        switch UInt32(bitPattern: value) {
        case UInt32(bitPattern: kIOReturnSuccess): .success
        case UInt32(bitPattern: kIOReturnAborted): .cancelled
        case UInt32(bitPattern: kIOReturnTimeout), 0xE000_4051:  // kIOUSBTransactionTimeout
            .timeout
        case 0xE000_404F: .stall  // kIOUSBPipeStalled
        case UInt32(bitPattern: kIOReturnOverrun): .babble
        case UInt32(bitPattern: kIOReturnBadArgument), UInt32(bitPattern: kIOReturnNoDevice): .inval
        default: .ioerror
        }
    }
}
#endif
