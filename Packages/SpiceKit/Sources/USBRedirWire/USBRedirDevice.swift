/// Result of a transfer executed by a device backend.
public struct USBTransferResult: Sendable, Equatable {
    public var status: USBRedirStatus
    /// Data read (IN transfers).
    public var data: [UInt8]
    /// Bytes transferred (OUT: bytes written; IN: `data.count`).
    public var actualLength: Int

    public init(status: USBRedirStatus, data: [UInt8] = [], actualLength: Int? = nil) {
        self.status = status
        self.data = data
        self.actualLength = actualLength ?? data.count
    }

    public static func failed(_ status: USBRedirStatus) -> USBTransferResult { USBTransferResult(status: status) }
}

/// A USB device that can be exposed to the guest through a usbredir slot — either a real
/// device on the Mac (`USBHost`) or an emulated one (`USBEmulation`).
///
/// Transfers on the same endpoint are issued one at a time and in order; different
/// endpoints may run concurrently.
public protocol USBRedirDevice: AnyObject, Sendable {
    /// Human-readable name for the UI.
    var displayName: String { get }

    /// Device + active-configuration description (re-read after configuration changes).
    func describe() async -> USBDeviceDescription

    /// Control transfer on endpoint 0 (`data` is the OUT payload).
    func control(setup: USBControlSetup, data: [UInt8]) async -> USBTransferResult

    /// Bulk transfer: OUT sends `data`; IN reads up to `length` bytes.
    func bulk(endpoint: UInt8, data: [UInt8], length: Int) async -> USBTransferResult

    /// Interrupt transfer: OUT sends `data`; IN reads up to `length` bytes (used for polling).
    func interrupt(endpoint: UInt8, data: [UInt8], length: Int) async -> USBTransferResult

    func setConfiguration(_ value: UInt8) async -> USBRedirStatus
    func configuration() async -> UInt8
    func setAltSetting(interface: UInt8, alt: UInt8) async -> USBRedirStatus
    func altSetting(interface: UInt8) async -> UInt8?

    /// Port reset. Returns `false` if the device is gone afterwards.
    func reset() async -> Bool

    /// Aborts pending transfers on an endpoint (they complete with `.cancelled`).
    func abort(endpoint: UInt8) async

    /// Releases the device (called once, on detach).
    func close() async
}
