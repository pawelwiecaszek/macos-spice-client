#if os(macOS)
import Foundation
import IOKit
import IOKit.usb
import USBRedirWire

/// Lists USB devices attached to the Mac and reports hot-plug changes.
///
/// Uses `IOServiceAddMatchingNotification` for arrival/removal of `IOUSBHostDevice`
/// services; the current list is published through `devices`.
public final class USBDeviceMonitor: @unchecked Sendable {
    // State is confined to `queue`; the stream continuation is thread-safe.
    public let devices: AsyncStream<[HostUSBDevice]>
    private let sink: AsyncStream<[HostUSBDevice]>.Continuation
    private let queue = DispatchQueue(label: "com.pawelwiecaszek.spiceclient.usb-monitor")
    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var started = false

    public init() {
        (devices, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        if addedIterator != 0 { IOObjectRelease(addedIterator) }
        if removedIterator != 0 { IOObjectRelease(removedIterator) }
        if let port { IONotificationPortDestroy(port) }
        sink.finish()
    }

    /// Starts monitoring and publishes the initial list.
    public func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
            self.port = port
            IONotificationPortSetDispatchQueue(port, queue)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let callback: IOServiceMatchingCallback = { refcon, iterator in
                guard let refcon else { return }
                let monitor = Unmanaged<USBDeviceMonitor>.fromOpaque(refcon).takeUnretainedValue()
                USBDeviceMonitor.drain(iterator)
                monitor.publish()
            }
            IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"),
                                             callback, refcon, &addedIterator)
            IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"),
                                             callback, refcon, &removedIterator)
            // Arm both notifications by draining the initial iterators.
            Self.drain(addedIterator)
            Self.drain(removedIterator)
            publish()
        }
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }

    private func publish() {
        sink.yield(Self.enumerate())
    }

    /// Current USB devices (excluding hubs and the Mac's own internal devices without names).
    public static func enumerate() -> [HostUSBDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [HostUSBDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let device = describe(service), !device.isHub { result.append(device) }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func describe(_ service: io_service_t) -> HostUSBDevice? {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }
        func number(_ key: String, of entry: io_registry_entry_t = service) -> Int? {
            (IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        func string(_ key: String) -> String? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        }
        guard let vendor = number("idVendor"), let product = number("idProduct") else { return nil }
        let deviceClass = UInt8(truncatingIfNeeded: number("bDeviceClass") ?? 0)

        var interfaces: [USBInterfaceInfo] = []
        var claimed = false
        var children: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS {
            while case let child = IOIteratorNext(children), child != 0 {
                defer { IOObjectRelease(child) }
                guard IOObjectConformsTo(child, "IOUSBHostInterface") != 0 else { continue }
                interfaces.append(USBInterfaceInfo(
                    number: UInt8(truncatingIfNeeded: number("bInterfaceNumber", of: child) ?? 0),
                    interfaceClass: UInt8(truncatingIfNeeded: number("bInterfaceClass", of: child) ?? 0),
                    interfaceSubclass: UInt8(truncatingIfNeeded: number("bInterfaceSubClass", of: child) ?? 0),
                    interfaceProtocol: UInt8(truncatingIfNeeded: number("bInterfaceProtocol", of: child) ?? 0)))
                // A driver attached below the interface means macOS owns it.
                var grandchildren: io_iterator_t = 0
                if IORegistryEntryGetChildIterator(child, kIOServicePlane, &grandchildren) == KERN_SUCCESS {
                    let first = IOIteratorNext(grandchildren)
                    if first != 0 {
                        claimed = true
                        IOObjectRelease(first)
                    }
                    IOObjectRelease(grandchildren)
                }
            }
            IOObjectRelease(children)
        }

        let name = string("USB Product Name") ?? string("kUSBProductString")
            ?? String(format: "USB device %04x:%04x", vendor, product)
        let classes = Set([deviceClass] + interfaces.map(\.interfaceClass))
        return HostUSBDevice(
            id: entryID, name: name, manufacturer: string("USB Vendor Name") ?? string("kUSBVendorString"),
            descriptor: USBFilter.Device(classes: classes, vendorID: UInt16(truncatingIfNeeded: vendor),
                                         productID: UInt16(truncatingIfNeeded: product),
                                         deviceVersion: UInt16(truncatingIfNeeded: number("bcdDevice") ?? 0)),
            interfaces: interfaces, claimedByMacOS: claimed)
    }
}
#endif
