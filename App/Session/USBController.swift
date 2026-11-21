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

    var id: UUID
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

    struct Attachment: Sendable {
        let slot: Int
        let id: UUID
        let detach: @Sendable () async -> Void
    }

    struct Environment {
        var attach: @Sendable (any USBRedirDevice, Bool, UUID) async throws -> Attachment
        var hostDevice: @MainActor (HostUSBDevice) throws -> any USBRedirDevice = { try HostUSBBackend($0) }
        var image: @MainActor (URL, @escaping @Sendable () -> Void) throws -> any USBRedirDevice = {
            try EmulatedCDROM(url: $0, onEject: $1)
        }
        var devices: @MainActor () -> [HostUSBDevice] = { HostUSBInventory.shared.devices }
        var startInventory: @MainActor () -> Void = { HostUSBInventory.shared.start() }
        var startAccess: @MainActor (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
        var stopAccess: @MainActor (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    }

    @ObservationIgnored private let events: AsyncStream<USBSlotEvent>
    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private let profile: ConnectionProfile
    @ObservationIgnored private var knownDeviceIDs: Set<UInt64>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private(set) var workers: [UUID: Task<Int, any Error>] = [:]
    private var pending: [UUID: AttachedUSB.Kind] = [:]
    @ObservationIgnored private var endedWhilePending: Set<UUID> = []
    private var detaching: [UUID: AttachedUSB.Kind] = [:]
    @ObservationIgnored private var rejectedWhilePending: Set<UUID> = []
    private var leases: [UUID: Attachment] = [:]
    @ObservationIgnored private var detachWorkers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var scopeReleases: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var started = false
    private(set) var stopped = false
    var mountingISO: Bool {
        (Array(pending.values) + Array(detaching.values)).contains { if case .iso = $0 { true } else { false } }
    }
    @ObservationIgnored private let log = Logger(subsystem: "com.pawelwiecaszek.spiceclient", category: "usb")

    init(session: SpiceSession, profile: ConnectionProfile, environment: Environment? = nil) {
        self.profile = profile
        self.events = session.usbEvents
        self.environment = environment ?? Environment(attach: { device, input, id in
            let lease = try await session.attachUSBWithLease(device, allowInputDevice: input, attachmentID: id)
            return Attachment(slot: lease.slot, id: lease.id, detach: { await lease.detach() })
        })
        isAllowed = profile.enableUSBRedirection != false
    }

    func start() {
        guard isAllowed, !started, !stopped else { return }
        started = true
        environment.startInventory()
        knownDeviceIDs = Set(environment.devices().map(\.id))
        let events = self.events
        tasks.append(Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self, !self.stopped else { return }
                self.handle(event)
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard !Task.isCancelled, let self, !self.stopped else { return }
                self.autoShareNewDevices()
            }
        })
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        for task in tasks { task.cancel() }
        tasks.removeAll()
        // Never cancel an attachment's socket write: retire admission and roll back its
        // identity-bound lease when it completes instead.
        lostWithConnection.append(contentsOf: attached.values)
        for slot in Array(attached.keys) { detach(slot: slot) }
        slotCount = 0
    }

    func setSlotCount(_ count: Int) {
        guard !stopped else { return }
        slotCount = isAllowed ? min(16, max(0, count)) : 0
    }

    var freeSlots: Int { stopped ? 0 : max(0, slotCount - leases.count - pending.count) }
    var mountedISO: AttachedUSB? { attached.values.first { if case .iso = $0.kind { true } else { false } } }

    func isRedirected(_ device: HostUSBDevice) -> Bool {
        attached.values.contains { $0.kind == .host(device.id) }
    }

    /// Keyboard-like devices still require per-attach confirmation.
    func unavailableReason(_ device: HostUSBDevice) -> String? {
        if !isAllowed { return String(localized: "USB sharing is disabled by the connection file") }
        if stopped { return String(localized: "session ended") }
        if device.isHub { return String(localized: "USB hubs cannot be redirected") }
        if profile.enableSmartcard == false, device.descriptor.classes.contains(0x0B) {
            return String(localized: "smartcard sharing is disabled by the connection file")
        }
        if let filter = profile.usbFilter, !filter.allows(device.descriptor) {
            return String(localized: "blocked by the connection file")
        }
        if !isRedirected(device), device.claimedByMacOS {
            return String(localized: "in use by macOS; this app cannot capture it")
        }
        if busyDeviceIDs.contains(device.id) || detaching.values.contains(.host(device.id)) { return String(localized: "connecting") }
        return nil
    }

    func handle(_ event: USBSlotEvent) {
        guard !stopped else { return }
        switch event {
        case .attached, .detached:
            break // Legacy slot-only events cannot authorize removing a replacement.
        case .attachmentEnded(let slot, let id, let reason):
            if pending[id] != nil {
                endedWhilePending.insert(id)
                if reason == .guestRejected { rejectedWhilePending.insert(id) }
            }
            guard let item = attached[slot], item.id == id else { return }
            attached.removeValue(forKey: slot)
            leases.removeValue(forKey: id)
            scopeReleases.removeValue(forKey: id)?()
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
        guard !mountingISO, mountedISO == nil, let id = reserve(.iso(url)) else { return }
        let scoped = environment.startAccess(url)
        let release: @MainActor () -> Void = { [environment] in
            if scoped { environment.stopAccess(url) }
        }
        let onEject: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.guestEjected(id) }
        }
        launch(id: id, name: url.lastPathComponent, kind: .iso(url), release: release) { [environment] in
            try environment.image(url, onEject)
        }
    }

    private func guestEjected(_ id: UUID) {
        // A late callback from an older image must not eject a new mount of the same URL.
        if pending[id] != nil { endedWhilePending.insert(id) }
        guard let item = attached.values.first(where: { $0.id == id }) else { return }
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
        guard unavailableReason(device) == nil, !isRedirected(device), freeSlots > 0 else { return }
        let isInputDevice = device.isKeyboardOrMouse
        if isInputDevice, !confirmed, !confirmInputDevice(device) { return }
        guard let id = reserve(.host(device.id)) else { return }
        busyDeviceIDs.insert(device.id)
        launch(id: id, name: device.name, kind: .host(device.id), allowInputDevice: isInputDevice) { [environment] in
            try environment.hostDevice(device)
        }
    }

    private func reserve(_ kind: AttachedUSB.Kind, id: UUID = UUID()) -> UUID? {
        guard isAllowed, !stopped, freeSlots > 0, !pending.values.contains(kind), !detaching.values.contains(kind),
              pending[id] == nil, leases[id] == nil, detachWorkers[id] == nil,
              !attached.values.contains(where: { $0.kind == kind }) else { return nil }
        pending[id] = kind
        return id
    }

    @discardableResult
    private func launch(id: UUID, name: String, kind: AttachedUSB.Kind, allowInputDevice: Bool = false,
                        release: @escaping @MainActor () -> Void = {},
                        factory: @escaping @MainActor () throws -> any USBRedirDevice) -> Task<Int, any Error> {
        let task = Task { @MainActor in
            defer {
                pending.removeValue(forKey: id)
                endedWhilePending.remove(id)
                rejectedWhilePending.remove(id)
                workers.removeValue(forKey: id)
                if case .host(let deviceID) = kind { busyDeviceIDs.remove(deviceID) }
            }
            var device: (any USBRedirDevice)?
            do {
                guard !stopped else { throw CancellationError() }
                let created = try factory()
                device = created
                let lease = try await environment.attach(created, allowInputDevice, id)
                guard !stopped, !endedWhilePending.contains(id) else {
                    await lease.detach()
                    if !stopped, rejectedWhilePending.contains(id) { throw USBAttachError.rejectedByGuestFilter }
                    throw CancellationError()
                }
                leases[id] = lease
                scopeReleases[id] = release
                attached[lease.slot] = AttachedUSB(id: id, slot: lease.slot, name: name, kind: kind)
                return lease.slot
            } catch {
                await device?.close()
                release()
                if !stopped, !(error is CancellationError) { errorMessage = describe(error, item: name) }
                throw error
            }
        }
        workers[id] = task
        return task
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
        try await attachSmartcardReaderWithLease(reader, name: name).slot
    }

    func attachSmartcardReaderWithLease(_ reader: EmulatedCCIDReader, name: String,
                                       attachmentID: UUID = UUID()) async throws -> Attachment {
        guard isAllowed, profile.enableSmartcard != false else { throw USBAttachError.blockedByConnectionFile }
        guard let id = reserve(.smartcardReader, id: attachmentID) else { throw USBAttachError.slotBusy }
        let slot = try await launch(id: id, name: name, kind: .smartcardReader) { reader }.value
        guard attached[slot]?.id == id else {
            await detach(attachmentID: id)
            throw CancellationError()
        }
        return Attachment(slot: slot, id: id, detach: { [weak self] in await self?.detach(attachmentID: id) })
    }

    // MARK: Reconnect (M8)

    private var restorable: [AttachedUSB] { Array(attached.values) + lostWithConnection }

    var restorableDeviceIDs: [UInt64] {
        Array(Set(restorable.compactMap { if case .host(let id) = $0.kind { id } else { nil } }))
    }

    var restorableISOs: [URL] {
        Array(Set(restorable.compactMap { if case .iso(let url) = $0.kind { url } else { nil } }))
    }

    /// Shares again what was shared before the connection dropped. Devices unplugged in
    /// the meantime are skipped; failures are reported like a manual attempt.
    func restore(deviceIDs: [UInt64], isos: [URL]) {
        guard isAllowed else { return }
        for id in deviceIDs {
            guard let device = environment.devices().first(where: { $0.id == id }), !isRedirected(device) else { continue }
            redirect(device, confirmed: true)
        }
        if mountedISO == nil, let url = isos.first { mountISO(url) }
    }

    func detach(slot: Int) {
        guard let item = attached[slot] else { return }
        _ = beginDetach(attachmentID: item.id)
    }

    func detach(attachmentID: UUID) async {
        await beginDetach(attachmentID: attachmentID)?.value
    }

    private func beginDetach(attachmentID: UUID) -> Task<Void, Never>? {
        if let existing = detachWorkers[attachmentID] { return existing }
        guard let item = attached.values.first(where: { $0.id == attachmentID }),
              let lease = leases[item.id] else { return nil }
        attached.removeValue(forKey: item.slot)
        let release = scopeReleases.removeValue(forKey: item.id)
        detaching[item.id] = item.kind
        let worker = Task { @MainActor in
            await lease.detach()
            leases.removeValue(forKey: item.id)
            detaching.removeValue(forKey: item.id)
            detachWorkers.removeValue(forKey: item.id)
            release?()
        }
        detachWorkers[item.id] = worker
        return worker
    }

    private func autoShareNewDevices() {
        let current = Set(environment.devices().map(\.id))
        defer { knownDeviceIDs = current }
        // Only devices plugged in after the session started are auto-shared.
        guard profile.enableUSBAutoshare, let known = knownDeviceIDs, freeSlots > 0 else { return }
        for device in environment.devices() where !known.contains(device.id) {
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
