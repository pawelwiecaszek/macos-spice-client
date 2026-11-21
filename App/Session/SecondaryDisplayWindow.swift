import AppKit
import SpiceKit

/// A window for an additional guest head or display channel. Pointer positions
/// carry the independently validated guest input selector.
@MainActor
final class SecondaryDisplayWindow: NSObject, NSWindowDelegate, RemoteDisplayViewDelegate {
    let display: UInt8
    let view: RemoteDisplayView
    let window: NSWindow
    private(set) var wasClosed = false
    private weak var owner: SessionController?

    init?(display: UInt8, owner: SessionController, title: String, settings: AppSettings) {
        guard let renderer = try? MetalRenderer() else { return nil }
        self.display = display
        self.owner = owner
        view = RemoteDisplayView(renderer: renderer)
        view.displayID = display
        view.setAccessibilityLabel(String(localized: "Display \(Int(display) + 1) of \(title)"))
        view.sendsCommandToGuest = settings.sendCommandKeyToGuest
        view.hotkeys = HotkeyMatcher(profile: owner.profile)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        view.delegate = self
        window.contentView = view
        window.title = String(localized: "\(title) — Display \(Int(display) + 1)")
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
    }

    /// Shares its channel's upload texture; the head owns only presentation state.
    func showHead(width: Int, height: Int, retina: Bool) {
        guard !window.isVisible else { return }
        let scale = retina ? (window.screen?.backingScaleFactor ?? 2) : 1
        var size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame.size {
            let fit = min(1, min(screen.width / size.width, max(1, screen.height - 60) / size.height))
            size.width *= fit; size.height *= fit
        }
        window.setContentSize(size)
        window.center()
        window.orderFront(nil)
    }

    func close() {
        view.stop()
        window.delegate = nil
        window.close()
    }

    // MARK: RemoteDisplayViewDelegate

    func displayView(_ view: RemoteDisplayView, send event: InputEvent) {
        owner?.displayView(view, send: event)
    }

    func displayView(_ view: RemoteDisplayView, perform action: HotkeyAction) {
        owner?.displayView(view, perform: action)
    }

    func displayView(_ view: RemoteDisplayView, didResizeTo pixelSize: CGSize) {
        owner?.displayView(view, didResizeTo: pixelSize)
    }

    func displayView(_ view: RemoteDisplayView, didDropFiles urls: [URL]) {
        owner?.displayView(view, didDropFiles: urls)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        wasClosed = true
        view.stop()
    }
}
