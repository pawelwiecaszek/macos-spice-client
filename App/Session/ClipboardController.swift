import AppKit
import ImageIO
import SpiceKit

/// Shares the Mac clipboard with the guest through spice-vdagent (text and PNG images).
///
/// Mac → guest: while the session window is key, a new pasteboard change is *offered*
/// (types only); data is sent when the guest asks for it, i.e. when the user pastes there.
/// Guest → Mac: when the guest copies, the data is fetched and written to the pasteboard.
@MainActor
final class ClipboardController {
    private let session: SpiceSession
    private let settings: AppSettings
    /// Set by the owner: `true` while the session window is key.
    var isWindowActive: () -> Bool = { false }
    private let pasteboard = NSPasteboard.general
    private var tasks: [Task<Void, Never>] = []

    private var available = false
    /// Pasteboard change count we last offered or wrote ourselves.
    private var handledChangeCount: Int
    private var offeredTypes: [ClipboardDataType] = []
    /// Type we asked the guest for; unsolicited data is ignored.
    private var pendingRequest: ClipboardDataType?
    /// Largest image accepted from the guest (pixels).
    private static let maxImagePixels = 64 * 1024 * 1024

    init(session: SpiceSession, settings: AppSettings) {
        self.session = session
        self.settings = settings
        handledChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        let events = session.clipboardEvents
        tasks.append(Task { [weak self] in
            for await event in events { await self?.handle(event) }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await self?.offerIfChanged()
            }
        })
    }

    func stop() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
    }

    func setAvailable(_ value: Bool) {
        available = value
        // Let a freshly connected agent see what's already on the Mac clipboard.
        if value { handledChangeCount = -1 }
    }

    // MARK: Mac → guest

    private func offerIfChanged() async {
        guard available, settings.shareClipboard, isWindowActive() else { return }
        let count = pasteboard.changeCount
        guard count != handledChangeCount else { return }
        handledChangeCount = count
        let types = shareableTypes()
        offeredTypes = types
        if types.isEmpty {
            await session.releaseClipboard()
        } else {
            await session.offerClipboard(types)
        }
    }

    private func shareableTypes() -> [ClipboardDataType] {
        var types: [ClipboardDataType] = []
        let available = pasteboard.types ?? []
        if available.contains(.string) { types.append(.utf8Text) }
        if available.contains(.png) || available.contains(.tiff) { types.append(.png) }
        return types
    }

    private func pasteboardData(for type: ClipboardDataType) -> [UInt8] {
        switch type {
        case .utf8Text:
            return Array((pasteboard.string(forType: .string) ?? "").utf8)
        case .png:
            if let png = pasteboard.data(forType: .png) { return [UInt8](png) }
            if let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                return [UInt8](png)
            }
            return []
        default:
            return []
        }
    }

    // MARK: Guest → Mac

    private func handle(_ event: ClipboardMessage) async {
        switch event {
        case .grab(_, let types):
            guard settings.shareClipboard else { return }
            if let type = [ClipboardDataType.utf8Text, .png].first(where: types.contains) {
                pendingRequest = type
                await session.requestClipboard(type)
            }
        case .request(_, let type):
            // Only exactly what was offered: if the Mac clipboard changed since (e.g. the user
            // copied a password in another app), the guest gets nothing. An empty reply keeps
            // the guest from waiting.
            let allowed = settings.shareClipboard && offeredTypes.contains(type)
                && pasteboard.changeCount == handledChangeCount
            var data = allowed ? pasteboardData(for: type) : []
            if data.count > ClipboardCodec.maxDataSize { data = [] }  // never send a truncated image
            await session.provideClipboard(type, data: data)
        case .data(_, let type, let bytes):
            guard settings.shareClipboard, type == pendingRequest, !bytes.isEmpty else { return }
            pendingRequest = nil
            write(type, bytes)
        case .release:
            break  // keep whatever the Mac clipboard holds
        }
    }

    private func write(_ type: ClipboardDataType, _ bytes: [UInt8]) {
        switch type {
        case .utf8Text:
            pasteboard.clearContents()
            pasteboard.setString(String(decoding: bytes, as: UTF8.self), forType: .string)
        case .png:
            // Re-encode through ImageIO: validates the guest's bytes before other apps see them.
            // Check the declared size from the header before decoding anything.
            let data = Data(bytes)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width * height <= Self.maxImagePixels,
                  let rep = NSBitmapImageRep(data: data),
                  let png = rep.representation(using: .png, properties: [:]) else {
                return
            }
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
        default:
            return
        }
        // Don't offer the guest's own data back to it.
        handledChangeCount = pasteboard.changeCount
        offeredTypes = []
    }
}
