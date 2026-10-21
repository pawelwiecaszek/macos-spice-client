import AppKit
import Observation
import SpiceKit
import UniformTypeIdentifiers
import os

/// What occupies a usbredir slot.
struct AttachedUSB: Equatable {
    enum Kind: Equatable {
        case iso(URL)
        case host(UInt64)
        case smartcardReader
    }

    var slot: Int
    var name: String
    var kind: Kind
}

/// Shared list of USB devices on the Mac (one IOKit monitor for the whole app).
@MainActor
@Observable
final class HostUSBInventory {
    static let shared = HostUSBInventory()
    private(set) var devices: [HostUSBDevice] = []
    @ObservationIgnored private let monitor = USBDeviceMonitor()
    @ObservationIgnored private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        monitor.start()
        let stream = monitor.devices
        task = Task { [weak self] in
            for await list in stream { self?.devices = list }
        }
    }
}

/// USB redirection and ISO mounting for one session (AGENTS.md §7a/§7b).
@MainActor
@Observable
final class USBController {
    private(set) var slotCount = 0
    private(set) var attached: [Int: AttachedUSB] = [:]
    private(set) var busyDeviceIDs: Set<UInt64> = []
    /// Items whose slot closed with the connection; brought back after a reconnect (M8).
    @ObservationIgnored private var lostWithConnection: [AttachedUSB] = []
    var errorMessage: String?

    let isAllowed: Bool
    var inventory: HostUSBInventory { .shared }

    @ObservationIgnored private let session: SpiceSession
    @ObservationIgnored private let profile: ConnectionProfile
    @ObservationIgnored private var knownDeviceIDs: Set<UInt64>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let log = Logger(subsystem: "com.pawelwiecaszek.spiceclient", category: "usb")

    init(session: SpiceSession, profile: ConnectionProfile) {
        self.session = session
        self.profile = profile
        isAllowed = profile.enableUSBRedirection != false
    }

    func start() {
        guard isAllowed else { return }
        HostUSBInventory.shared.start()
        let events = session.usbEvents
        tasks.append(Task { [weak self] in
            for await event in events { self?.handle(event) }
        })
        tasks.append(Task { [weak self] in
            // Auto-share watches the inventory for newly plugged devices.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.autoShareNewDevices()
            }
        })
    }

    func stop() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
    }

    func setSlotCount(_ count: Int) {
        slotCount = isAllowed ? count : 0
    }

    var freeSlots: Int { max(0, slotCount - attached.count) }
    var mountedISO: AttachedUSB? { attached.values.first { if case .iso = $0.kind { true } else { false } } }

    func isRedirected(_ device: HostUSBDevice) -> Bool {
        attached.values.contains { $0.kind == .host(device.id) }
    }

    /// Why a device can't be redirected, or `nil` if it can.
    /// Keyboard-like devices (e.g. YubiKeys) are allowed after a confirmation, see `redirect`.
    func unavailableReason(_ device: HostUSBDevice) -> String? {
        if let filter = profile.usbFilter, !filter.allows(device.descriptor) { return String(localized: "blocked by the connection file") }
        return nil
    }

    private func handle(_ event: USBSlotEvent) {
        switch event {
        case .attached:
            break  // recorded by the caller, which knows the kind
        case .detached(let slot, let reason):
            guard let item = attached.removeValue(forKey: slot) else { return }
            if reason == .guestRejected {
                errorMessage = String(localized: "The virtual machine rejected “\(item.name)”.")
            } else if reason == .channelClosed {
                lostWithConnection.append(item)
            }
        }
    }

    // MARK: ISO

    func chooseAndMountISO() {
        let panel = NSOpenPanel()
        var types: [UTType] = [UTType(filenameExtension: "iso") ?? .diskImage, .diskImage]
        if let img = UTType(filenameExtension: "img") { types.append(img) }
        panel.allowedContentTypes = types
        panel.message = String(localized: "Choose a disc image to insert into the virtual machine")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        mountISO(url)
    }

    func mountISO(_ url: URL) {
        let session = self.session
        let onEject: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.guestEjected(url) }
        }
        Task {
            do {
                let drive = try EmulatedCDROM(url: url, onEject: onEject)
                let slot = try await session.attachUSB(drive)
                attached[slot] = AttachedUSB(slot: slot, name: url.lastPathComponent, kind: .iso(url))
            } catch {
                errorMessage = describe(error, item: url.lastPathComponent)
            }
        }
    }

    private func guestEjected(_ url: URL) {
        guard let item = attached.values.first(where: { $0.kind == .iso(url) }) else { return }
        detach(slot: item.slot)
    }

    // MARK: Host devices

    func toggle(_ device: HostUSBDevice) {
        if let item = attached.values.first(where: { $0.kind == .host(device.id) }) {
            detach(slot: item.slot)
        } else {
            // Let the menu close before a confirmation alert may appear.
            Task { @MainActor in self.redirect(device) }
        }
    }

    /// - Parameter confirmed: the user already agreed to redirect this keyboard-like device
    ///   (it was shared before the connection dropped).
    func redirect(_ device: HostUSBDevice, confirmed: Bool = false) {
        guard unavailableReason(device) == nil, !busyDeviceIDs.contains(device.id) else { return }
        let isInputDevice = device.isKeyboardOrMouse
        if isInputDevice, !confirmed, !confirmInputDevice(device) { return }
        busyDeviceIDs.insert(device.id)
        let session = self.session
        Task {
            defer { busyDeviceIDs.remove(device.id) }
            do {
                let backend = try HostUSBBackend(device)
                do {
                    let slot = try await session.attachUSB(backend, allowInputDevice: isInputDevice)
                    attached[slot] = AttachedUSB(slot: slot, name: device.name, kind: .host(device.id))
                } catch {
                    await backend.close()
                    throw error
                }
            } catch {
                errorMessage = describe(error, item: device.name)
            }
        }
    }

    /// Redirecting a keyboard-like device takes it away from macOS; ask first (AGENTS.md §7a).
    private func confirmInputDevice(_ device: HostUSBDevice) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Redirect “\(device.name)”?")
        alert.informativeText = String(localized: """
            This device acts as a keyboard or mouse (security keys such as YubiKey do this to type \
            one-time codes). While it is redirected, your Mac can't use it. If it is your only \
            keyboard or mouse, you won't be able to type or point on the Mac until you disconnect it.
            """)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Redirect"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Attaches an emulated USB smartcard reader (see `SmartcardController`).
    func attachSmartcardReader(_ reader: EmulatedCCIDReader, name: String) async throws -> Int {
        let slot = try await session.attachUSB(reader)
        attached[slot] = AttachedUSB(slot: slot, name: name, kind: .smartcardReader)
        return slot
    }

    // MARK: Reconnect (M8)

    private var restorable: [AttachedUSB] { Array(attached.values) + lostWithConnection }

    var restorableDeviceIDs: [UInt64] {
        restorable.compactMap { if case .host(let id) = $0.kind { id } else { nil } }
    }

    var restorableISOs: [URL] {
        restorable.compactMap { if case .iso(let url) = $0.kind { url } else { nil } }
    }

    /// Shares again what was shared before the connection dropped. Devices unplugged in
    /// the meantime are skipped; failures are reported like a manual attempt.
    func restore(deviceIDs: [UInt64], isos: [URL]) {
        guard isAllowed else { return }
        for id in deviceIDs {
            guard let device = inventory.devices.first(where: { $0.id == id }), !isRedirected(device) else { continue }
            redirect(device, confirmed: true)
        }
        if mountedISO == nil, let url = isos.first { mountISO(url) }
    }

    func detach(slot: Int) {
        let session = self.session
        attached.removeValue(forKey: slot)
        Task { await session.detachUSB(slot: slot) }
    }

    private func autoShareNewDevices() {
        let current = Set(inventory.devices.map(\.id))
        defer { knownDeviceIDs = current }
        // Only devices plugged in after the session started are auto-shared.
        guard profile.enableUSBAutoshare, let known = knownDeviceIDs, freeSlots > 0 else { return }
        for device in inventory.devices where !known.contains(device.id) {
            // Keyboard-like devices are never auto-shared: they need an explicit confirmation.
            guard unavailableReason(device) == nil, !device.isKeyboardOrMouse,
                  profile.usbFilter?.allows(device.descriptor) ?? true else { continue }
            log.info("auto-sharing newly plugged USB device")
            redirect(device)
        }
    }

    private func describe(_ error: any Error, item: String) -> String {
        switch error {
        case USBAttachError.slotBusy:
            String(localized: "No free USB slot for “\(item)”. Disconnect another device first.")
        case USBAttachError.guestNotReady:
            String(localized: "The virtual machine’s USB redirection isn’t responding.")
        case USBAttachError.rejectedByGuestFilter:
            String(localized: "The virtual machine doesn’t accept “\(item)”.")
        case USBAttachError.blockedByConnectionFile:
            String(localized: "The connection file doesn’t allow “\(item)” to be shared with this virtual machine.")
        case USBAttachError.keyboardOrMouse:
            String(localized: "Keyboards and mice can’t be redirected.")
        case let error as any LocalizedError:
            error.errorDescription ?? String(describing: error)
        default:
            String(localized: "“\(item)” could not be connected (\(error.localizedDescription)).")
        }
    }
}
