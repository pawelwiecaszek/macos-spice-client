import AppKit
import Observation
import SpiceKit

/// One smartcard share, through the native channel or a USB CCID attachment.
@MainActor
@Observable
final class SmartcardController {
    struct Attachment: Sendable {
        let id: UUID
        let usesChannel: Bool
        let isCurrent: @MainActor @Sendable () -> Bool
        let remove: @MainActor @Sendable () async -> Void
    }

    struct ReaderSnapshot: Sendable {
        var available = true
        var readers: [SmartcardReaderInfo] = []
    }

    struct Environment {
        var readers: @Sendable () async -> ReaderSnapshot
        var card: @MainActor (String) throws -> any SmartcardCard & CCIDCard
        var insert: @Sendable (any SmartcardCard, UUID) async throws -> Attachment
        var insertUSB: @MainActor (EmulatedCCIDReader, String, UUID) async throws -> Attachment
    }

    private(set) var readers: [SmartcardReaderInfo] = []
    private(set) var sharedReader: String?
    private(set) var restorableReader: String?
    private(set) var hostAvailable = true
    private(set) var stopped = false
    var errorMessage: String?

    private var channelAvailable = false
    private var pendingID: UUID?
    private var releasingID: UUID?
    @ObservationIgnored private var pendingReader: String?
    @ObservationIgnored private var pendingUsesChannel = false
    @ObservationIgnored private var pendingRevoked = false
    @ObservationIgnored private var attachment: Attachment?
    @ObservationIgnored private let allowed: Bool
    @ObservationIgnored private let usb: USBController
    @ObservationIgnored private let events: AsyncStream<SmartcardEvent>
    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var started = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private(set) var worker: Task<Void, Never>?
    @ObservationIgnored private(set) var releaseWorker: Task<Void, Never>?

    init(session: SpiceSession, usb: USBController, environment: Environment? = nil) {
        self.allowed = session.smartcardAllowed
        self.usb = usb
        self.events = session.smartcardEvents
        self.environment = environment ?? Environment(
            readers: {
                await Task.detached {
                    let available = SmartcardHost.isAvailable
                    return ReaderSnapshot(available: available, readers: available ? SmartcardHost.readers() : [])
                }.value
            },
            card: { MacSmartcard(readerName: $0) },
            insert: { card, id in
                let lease = try await session.insertSmartcardWithLease(card, attachmentID: id)
                return Attachment(id: lease.id, usesChannel: true, isCurrent: { true }, remove: { await lease.remove() })
            },
            insertUSB: { reader, name, id in
                let lease = try await usb.attachSmartcardReaderWithLease(reader, name: name, attachmentID: id)
                return Attachment(id: lease.id, usesChannel: false,
                    isCurrent: { usb.attached[lease.slot]?.id == lease.id },
                    remove: { await usb.detach(attachmentID: lease.id) })
            })
    }

    var isAvailable: Bool { allowed && !stopped && (channelAvailable || usb.slotCount > 0) }
    var isBusy: Bool { pendingID != nil || releasingID != nil }
    var canShare: Bool { isAvailable && hostAvailable && !isBusy && (channelAvailable || usb.freeSlots > 0) }

    var availabilityNote: String? {
        if !hostAvailable { return String(localized: "macOS smartcard access is unavailable for this app.") }
        if readers.isEmpty { return String(localized: "No smartcard readers on this Mac") }
        return nil
    }

    var transportNote: String {
        channelAvailable
            ? String(localized: "Shared through the VM's smartcard reader.")
            : String(localized: "Appears in the VM as a USB smartcard reader (uses one USB slot).")
    }

    func start() {
        guard allowed, !started, !stopped else { return }
        started = true
        let events = self.events
        tasks.append(Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self, !self.stopped else { return }
                self.handle(event)
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.stopped else { return }
                await self.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        })
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        for task in tasks { task.cancel() }
        tasks.removeAll()
        unshare(clearRestorable: false)
    }

    func setChannelAvailable(_ available: Bool) {
        guard !stopped else { return }
        channelAvailable = available
        if !available, attachment?.usesChannel == true || (pendingID != nil && pendingUsesChannel) {
            unshare(clearRestorable: false)
        }
    }

    func refresh() async {
        guard isAvailable, !Task.isCancelled else { return }
        let snapshot = await environment.readers()
        guard isAvailable, !Task.isCancelled else { return }
        hostAvailable = snapshot.available
        readers = snapshot.available ? snapshot.readers : []
        if let pendingReader, !readers.contains(where: { $0.name == pendingReader && $0.hasCard }) {
            unshare()
        }
        guard let shared = sharedReader, let attachment else { return }
        if !readers.contains(where: { $0.name == shared && $0.hasCard }) {
            unshare()
        } else if !attachment.isCurrent() {
            // The UUID, not a reused slot number, identifies the emulated reader.
            unshare(clearRestorable: false)
        }
    }

    func handle(_ event: SmartcardEvent) {
        guard !stopped else { return }
        guard case .attachmentRemoved(let id) = event else { return }
        if pendingID == id { pendingRevoked = true }
        if attachment?.id == id {
            attachment = nil
            sharedReader = nil
        }
    }

    func toggle(_ reader: SmartcardReaderInfo) {
        if sharedReader == reader.name { unshare() } else { share(reader) }
    }

    func share(_ reader: SmartcardReaderInfo) {
        guard sharedReader == nil, canShare, reader.hasCard,
              readers.contains(where: { $0.name == reader.name && $0.hasCard }) else { return }
        let id = UUID()
        let useChannel = channelAvailable
        pendingID = id
        pendingReader = reader.name
        pendingUsesChannel = useChannel
        pendingRevoked = false
        worker = Task { @MainActor in
            defer {
                pendingID = nil
                pendingReader = nil
                pendingRevoked = false
                worker = nil
            }
            var card: (any SmartcardCard & CCIDCard)?
            var emulated: EmulatedCCIDReader?
            do {
                guard !stopped, !pendingRevoked else { return }
                let created = try environment.card(reader.name)
                card = created
                let lease: Attachment
                if useChannel {
                    lease = try await environment.insert(created, id)
                } else {
                    let readerDevice = EmulatedCCIDReader(card: created)
                    emulated = readerDevice
                    lease = try await environment.insertUSB(readerDevice, reader.name, id)
                }
                guard !stopped, !pendingRevoked, lease.id == id, lease.isCurrent() else {
                    await lease.remove()
                    return
                }
                attachment = lease
                sharedReader = reader.name
                restorableReader = reader.name
            } catch {
                if let emulated { await emulated.close() } else { await card?.disconnect() }
                if !stopped, !pendingRevoked, !(error is CancellationError) { errorMessage = describe(error) }
            }
        }
    }

    func unshare() { unshare(clearRestorable: true) }

    private func unshare(clearRestorable: Bool) {
        if clearRestorable { restorableReader = nil }
        if pendingID != nil { pendingRevoked = true }
        guard let current = attachment else { return }
        attachment = nil
        sharedReader = nil
        releasingID = current.id
        // Removal owns its socket writes; revoking the UI never cancels this task.
        releaseWorker = Task { @MainActor in
            await current.remove()
            if releasingID == current.id {
                releasingID = nil
                releaseWorker = nil
            }
        }
    }

    func restore(readerName: String) async {
        for _ in 0..<10 {
            guard !stopped, !Task.isCancelled else { return }
            if let reader = readers.first(where: { $0.name == readerName && $0.hasCard }) {
                share(reader)
                return
            }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
    }

    private func describe(_ error: any Error) -> String {
        switch error {
        case SmartcardError.readerNotAccepted:
            String(localized: "The virtual machine's smartcard reader didn't respond.")
        case SmartcardError.cardAlreadyShared:
            String(localized: "A card is already shared. Stop sharing it first.")
        case SmartcardError.noATR:
            String(localized: "The card didn't identify itself.")
        case USBAttachError.slotBusy:
            String(localized: "No free USB slot for the smartcard reader. Disconnect a USB device or ISO first.")
        case USBAttachError.guestNotReady:
            String(localized: "The virtual machine's USB redirection isn't responding.")
        case USBAttachError.blockedByConnectionFile, USBAttachError.rejectedByGuestFilter:
            String(localized: "USB smartcard readers aren't allowed for this virtual machine.")
        case let error as any LocalizedError:
            error.errorDescription ?? String(describing: error)
        default:
            error.localizedDescription
        }
    }
}
