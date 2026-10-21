import Foundation
import USBRedirWire

/// A USB device attached to the Mac, as listed in the UI.
public struct HostUSBDevice: Sendable, Hashable, Identifiable {
    /// IORegistry entry ID (stable while the device stays plugged in).
    public var id: UInt64
    public var name: String
    public var manufacturer: String?
    public var descriptor: USBFilter.Device
    /// Interfaces with their class triple, for HID keyboard/mouse detection.
    public var interfaces: [USBInterfaceInfo]
    /// `true` when macOS drivers own one or more interfaces (capture may fail).
    public var claimedByMacOS: Bool

    public init(id: UInt64, name: String, manufacturer: String? = nil, descriptor: USBFilter.Device,
                interfaces: [USBInterfaceInfo] = [], claimedByMacOS: Bool = false) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.descriptor = descriptor
        self.interfaces = interfaces
        self.claimedByMacOS = claimedByMacOS
    }

    /// HID boot keyboards/mice are never offered for redirection (AGENTS.md §7a).
    public var isKeyboardOrMouse: Bool {
        interfaces.contains { $0.interfaceClass == 3 && $0.interfaceSubclass == 1 && ($0.interfaceProtocol == 1 || $0.interfaceProtocol == 2) }
    }

    /// USB hubs can't be redirected (usbredir tunnels a single device).
    public var isHub: Bool { descriptor.classes.contains(0x09) }
}

/// Errors opening a host device.
public enum HostUSBError: Error, Equatable, Sendable, LocalizedError {
    case notFound
    case inUseByMacOS
    case openFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "The USB device is no longer connected."
        case .inUseByMacOS:
            "macOS is using this device (for example as a disk, keyboard or card reader), so it can't be "
                + "redirected. Eject or quit the app using it and try again; some devices can only be "
                + "redirected by apps with Apple's virtualization device-access entitlement."
        case .openFailed(let reason):
            "The USB device could not be opened (\(reason))."
        }
    }
}
