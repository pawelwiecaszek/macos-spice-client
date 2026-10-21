import AppKit
import Observation
import SpiceKit

/// Smartcard sharing for one session: one card at a time.
///
/// Two transports, chosen automatically:
/// * the SPICE smartcard channel, when the VM has QEMU's `ccid-card-passthru` (§7c);
/// * otherwise an emulated USB CCID reader in a free USB redirection slot — this is what
///   works on stock Proxmox, whose QEMU is built without the passthru device.
@MainActor
@Observable
final class SmartcardController {
    private enum Mode: Equatable {
        case channel
        case usbReader(slot: Int)
    }

    private(set) var readers: [SmartcardReaderInfo] = []
    private(set) var sharedReader: String?
    private(set) var isBusy = false
    /// The reader to share again after a reconnect: kept when the connection drops, cleared
    /// when the user stops sharing or the card is removed (M8).
    private(set) var restorableReader: String?
    var errorMessage: String?

    /// The server offered a smartcard channel.
    private var channelAvailable = false
    @ObservationIgnored private let session: SpiceSession
    @ObservationIgnored private let usb: USBController
    @ObservationIgnored private var mode: Mode?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(session: SpiceSession, usb: USBController) {
        self.session = session
        self.usb = usb
    }

    /// A card can be shared through either transport.
    /// `enable-smartcard=0` in the connection file disables both transports.
    var isAvailable: Bool { session.smartcardAllowed && (channelAvailable || usb.slotCount > 0) }

    /// Sharing is possible right now (a transport with room for the card).
    var canShare: Bool { session.smartcardAllowed && (channelAvailable || usb.freeSlots > 0) }

    /// Short description of the transport for the menu.
    var transportNote: String {
        channelAvailable
            ? String(localized: "Shared through the VM's smartcard reader.")
            : String(localized: "Appears in the VM as a USB smartcard reader (uses one USB slot).")
    }

    func start() {
        let events = session.smartcardEvents
        tasks.append(Task { [weak self] in
            for await event in events {
                if case .removed = event, self?.mode == .channel { self?.clearShared() }
            }
        })
        tasks.append(Task { [weak self] in
            // CryptoTokenKit slot changes are polled: cheap, and avoids KVO across actors.
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        })
    }

    func stop() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
    }

    func setChannelAvailable(_ available: Bool) {
        channelAvailable = available
    }

    private func refresh() async {
        guard isAvailable else { return }
        let list = await Task.detached { SmartcardHost.readers() }.value
        if list != readers { readers = list }
        guard let shared = sharedReader, let mode else { return }
        // The card was pulled / the key unplugged: take it out of the guest too.
        if !list.contains(where: { $0.name == shared && $0.hasCard }) {
            unshare()
            return
        }
        // The USB slot went away (guest rejected the reader, channel closed).
        if case .usbReader(let slot) = mode, usb.attached[slot] == nil {
            clearShared()
        }
    }

    func toggle(_ reader: SmartcardReaderInfo) {
        if sharedReader == reader.name {
            unshare()
        } else {
            share(reader)
        }
    }

    func share(_ reader: SmartcardReaderInfo) {
        guard sharedReader == nil, !isBusy, canShare else { return }
        isBusy = true
        let card = MacSmartcard(readerName: reader.name)
        let session = self.session
        let useChannel = channelAvailable
        Task {
            defer { isBusy = false }
            do {
                if useChannel {
                    try await session.insertSmartcard(card)
                    mode = .channel
                } else {
                    // The reader opens the card when the guest powers it on.
                    let slot = try await usb.attachSmartcardReader(EmulatedCCIDReader(card: card), name: reader.name)
                    mode = .usbReader(slot: slot)
                }
                sharedReader = reader.name
                restorableReader = reader.name
            } catch {
                errorMessage = describe(error)
            }
        }
    }

    func unshare() {
        restorableReader = nil
        switch mode {
        case .channel:
            let session = self.session
            Task { await session.removeSmartcard() }
        case .usbReader(let slot):
            usb.detach(slot: slot)  // closes the reader, which ends the card session
            clearShared()
        case nil:
            break
        }
    }

    /// Shares the named reader again once it shows up (reconnect, M8).
    func restore(readerName: String) async {
        for _ in 0..<10 {
            if let reader = readers.first(where: { $0.name == readerName && $0.hasCard }) {
                share(reader)
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func clearShared() {
        mode = nil
        sharedReader = nil
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
