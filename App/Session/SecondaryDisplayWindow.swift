import AppKit
import SpiceKit

/// A window for an additional guest monitor (SPICE display channel 1…3). Input typed or
/// clicked here goes to the same session; pointer positions carry this display's id.
@MainActor
final class SecondaryDisplayWindow: NSObject, NSWindowDelegate, RemoteDisplayViewDelegate {
    let display: UInt8
    let view: RemoteDisplayView
    let window: NSWindow
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

    func show(width: Int, height: Int) {
        view.renderer.createSurface(width: width, height: height)
        if !window.isVisible {
            window.setContentSize(NSSize(width: width, height: height))
            window.center()
            window.orderFront(nil)
        }
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
        view.stop()
    }
}
