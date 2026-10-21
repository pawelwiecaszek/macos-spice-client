import AppKit
import Carbon.HIToolbox
import QuartzCore
import SpiceKit

/// Receives input and geometry changes from the display view.
@MainActor
protocol RemoteDisplayViewDelegate: AnyObject {
    func displayView(_ view: RemoteDisplayView, send event: InputEvent)
    func displayView(_ view: RemoteDisplayView, perform action: HotkeyAction)
    func displayView(_ view: RemoteDisplayView, didResizeTo pixelSize: CGSize)
    /// Files dropped onto the guest display (copied into the guest).
    func displayView(_ view: RemoteDisplayView, didDropFiles urls: [URL])
}

/// The remote desktop surface: a `CAMetalLayer`-backed view that captures keyboard and
/// mouse input while focused. Never draws overlays on top of the guest image.
@MainActor
final class RemoteDisplayView: NSView {
    weak var delegate: (any RemoteDisplayViewDelegate)?
    let renderer: MetalRenderer
    var hotkeys = HotkeyMatcher(profile: nil)
    /// SPICE display (monitor) this view shows; used for absolute pointer positions.
    var displayID: UInt8 = 0
    /// Forward Command-key combinations (as the Windows key) except reserved ones.
    var sendsCommandToGuest = true

    /// Client mode = absolute pointer; server mode = relative with pointer lock.
    var clientMouseMode = true {
        didSet {
            if clientMouseMode { releasePointerLock() }
            renderer.showsCursorOverlay = !clientMouseMode && guestCursorVisible
            window?.invalidateCursorRects(for: self)
        }
    }

    private(set) var isPointerLocked = false
    private var pressedScancodes: Set<UInt16> = []
    private var buttons: MouseButtonMask = []
    private var scrollAccumulator = CGPoint.zero
    private var motionRemainder = CGPoint.zero
    private var guestCursor: NSCursor?
    /// Guest asked to hide its cursor (client mode shows nothing then).
    var guestCursorVisible = true {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    private var displayLink: CADisplayLink?
    private var trackingArea: NSTrackingArea?

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    init(renderer: MetalRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Remote desktop"))
        setAccessibilityHelp(String(localized: "Screen of the virtual machine. Keys you type and clicks go to the virtual machine; drop files here to copy them into it."))
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        renderer.configure(layer)
        return layer
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Drag & drop (file transfer to the guest)

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        delegate?.displayView(self, didDropFiles: urls)
        return true
    }

    private func fileURLs(from info: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard let window else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: window)
        window.makeFirstResponder(self)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let layer = metalLayer else { return }
        let scale = window?.backingScaleFactor ?? 2
        layer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 0, size.height > 0 else { return }
        if layer.drawableSize != size {
            layer.drawableSize = size
            renderer.setNeedsDisplay()
            delegate?.displayView(self, didResizeTo: size)
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let layer = metalLayer else { return }
        renderer.draw(in: layer)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        releasePointerLock()
        releaseAllInput()
    }

    // MARK: Cursor

    func setGuestCursor(_ cursor: CursorImage?) {
        renderer.setCursor(cursor)
        if let cursor {
            guestCursor = Self.makeCursor(cursor, scale: displayScale)
        } else {
            guestCursor = Self.invisibleCursor
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        if clientMouseMode {
            addCursorRect(bounds, cursor: guestCursorVisible ? (guestCursor ?? .arrow) : Self.invisibleCursor)
        } else {
            addCursorRect(bounds, cursor: isPointerLocked ? Self.invisibleCursor : .arrow)
        }
    }

    /// Guest pixels per view point.
    private var displayScale: CGFloat {
        guard let layer = metalLayer, renderer.surfaceSize.width > 0 else { return 1 }
        let frame = renderer.surfaceFrame(in: layer.drawableSize)
        return frame.width / CGFloat(renderer.surfaceSize.width) / layer.contentsScale
    }

    private static let invisibleCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    private static func makeCursor(_ cursor: CursorImage, scale: CGFloat) -> NSCursor? {
        let image = cursor.image
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let data = image.pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                    decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let nsImage = NSImage(cgImage: cgImage, size: size)
        return NSCursor(image: nsImage, hotSpot: NSPoint(x: CGFloat(cursor.hotSpotX) * scale, y: CGFloat(cursor.hotSpotY) * scale))
    }

    // MARK: Coordinate mapping

    /// Maps a view point (flipped, points) to guest surface pixels, clamped to the surface.
    func guestPoint(for viewPoint: NSPoint) -> (x: UInt32, y: UInt32)? {
        guard let layer = metalLayer else { return nil }
        let (width, height) = renderer.surfaceSize
        guard width > 0, height > 0 else { return nil }
        let frame = renderer.surfaceFrame(in: layer.drawableSize)
        let px = viewPoint.x * layer.contentsScale, py = viewPoint.y * layer.contentsScale
        let gx = (px - frame.minX) * CGFloat(width) / frame.width
        let gy = (py - frame.minY) * CGFloat(height) / frame.height
        let x = min(max(0, Int(gx.rounded(.down))), width - 1)
        let y = min(max(0, Int(gy.rounded(.down))), height - 1)
        return (UInt32(x), UInt32(y))
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { handleMotion(event) }
    override func mouseDragged(with event: NSEvent) { handleMotion(event) }
    override func rightMouseDragged(with event: NSEvent) { handleMotion(event) }
    override func otherMouseDragged(with event: NSEvent) { handleMotion(event) }

    private func handleMotion(_ event: NSEvent) {
        if clientMouseMode {
            let point = convert(event.locationInWindow, from: nil)
            guard let guest = guestPoint(for: point) else { return }
            delegate?.displayView(self, send: .position(x: guest.x, y: guest.y, buttons: buttons, display: displayID))
        } else if isPointerLocked {
            motionRemainder.x += event.deltaX
            motionRemainder.y += event.deltaY
            let dx = Int32(motionRemainder.x.rounded(.towardZero))
            let dy = Int32(motionRemainder.y.rounded(.towardZero))
            motionRemainder.x -= CGFloat(dx)
            motionRemainder.y -= CGFloat(dy)
            if dx != 0 || dy != 0 {
                delegate?.displayView(self, send: .motion(dx: dx, dy: dy, buttons: buttons))
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if !clientMouseMode && !isPointerLocked {
            lockPointer()
            return  // the click only grabs the pointer
        }
        press(.left, event: event)
    }

    override func mouseUp(with event: NSEvent) { release(.left, event: event) }
    override func rightMouseDown(with event: NSEvent) { press(.right, event: event) }
    override func rightMouseUp(with event: NSEvent) { release(.right, event: event) }
    override func otherMouseDown(with event: NSEvent) { press(Self.button(for: event), event: event) }
    override func otherMouseUp(with event: NSEvent) { release(Self.button(for: event), event: event) }

    private static func button(for event: NSEvent) -> MouseButton {
        switch event.buttonNumber {
        case 2: .middle
        case 3: .side
        case 4: .extra
        default: .middle
        }
    }

    private func press(_ button: MouseButton, event: NSEvent) {
        if clientMouseMode { handleMotion(event) }
        buttons.insert(MouseButtonMask(button: button))
        delegate?.displayView(self, send: .press(button, buttons: buttons))
    }

    private func release(_ button: MouseButton, event: NSEvent) {
        let mask = MouseButtonMask(button: button)
        guard buttons.contains(mask) else { return }
        buttons.remove(mask)
        delegate?.displayView(self, send: .release(button, buttons: buttons))
    }

    override func scrollWheel(with event: NSEvent) {
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 16 : 1
        scrollAccumulator.y += event.scrollingDeltaY
        func emit(_ button: MouseButton) {
            let mask = MouseButtonMask(button: button)
            delegate?.displayView(self, send: .press(button, buttons: buttons.union(mask)))
            delegate?.displayView(self, send: .release(button, buttons: buttons))
        }
        while abs(scrollAccumulator.y) >= threshold {
            emit(scrollAccumulator.y > 0 ? .up : .down)
            scrollAccumulator.y -= scrollAccumulator.y > 0 ? threshold : -threshold
        }
        // SPICE has no horizontal wheel: buttons 6/7 are Back/Forward in QEMU, so sideways
        // scrolling is deliberately not forwarded.
        if event.phase == .ended || event.momentumPhase == .ended { scrollAccumulator = .zero }
    }

    // Pinch / rotate gestures are intentionally ignored.
    override func magnify(with event: NSEvent) {}
    override func rotate(with event: NSEvent) {}

    func lockPointer() {
        guard !clientMouseMode, !isPointerLocked else { return }
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        isPointerLocked = true
        motionRemainder = .zero
        window?.invalidateCursorRects(for: self)
    }

    func releasePointerLock() {
        guard isPointerLocked else { return }
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        isPointerLocked = false
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Keyboard

    private static let reservedCommandKeys: Set<Int> = [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_H, kVK_Tab, kVK_Space]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command) {
            if !sendsCommandToGuest || Self.reservedCommandKeys.contains(Int(event.keyCode)) {
                return super.performKeyEquivalent(with: event)
            }
            keyDown(with: event)
            return true
        }
        // Ctrl/Option combinations go to the guest, not to the menu bar.
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if let action = hotkeys.action(for: event) {
            delegate?.displayView(self, perform: action)
            return
        }
        guard let scancode = Keymap.scancode(forKeyCode: event.keyCode) else { return }
        pressedScancodes.insert(scancode)
        delegate?.displayView(self, send: .keyDown(scancode))
    }

    override func keyUp(with event: NSEvent) {
        guard let scancode = Keymap.scancode(forKeyCode: event.keyCode), pressedScancodes.contains(scancode) else { return }
        pressedScancodes.remove(scancode)
        delegate?.displayView(self, send: .keyUp(scancode))
    }

    /// Device-dependent modifier bits (IOKit `NX_DEVICE*KEYMASK`) per key code.
    private static let modifierMasks: [Int: UInt] = [
        kVK_Control: 0x0000_0001, kVK_Shift: 0x0000_0002, kVK_RightShift: 0x0000_0004,
        kVK_Command: 0x0000_0008, kVK_RightCommand: 0x0000_0010, kVK_Option: 0x0000_0020,
        kVK_RightOption: 0x0000_0040, kVK_RightControl: 0x0000_2000,
    ]

    private static let modifierScancodes: Set<UInt16> = [0x2A, 0x36, 0x1D, 0x11D, 0x38, 0x138, 0x15B, 0x15C, 0x3A]

    override func flagsChanged(with event: NSEvent) {
        let keyCode = Int(event.keyCode)
        guard let scancode = Keymap.scancode(forKeyCode: event.keyCode) else { return }
        if keyCode == kVK_CapsLock {
            // macOS reports a state change per physical press: send a full press.
            delegate?.displayView(self, send: .keyDown(scancode))
            delegate?.displayView(self, send: .keyUp(scancode))
            return
        }
        if (keyCode == kVK_Command || keyCode == kVK_RightCommand) && !sendsCommandToGuest { return }
        guard let mask = Self.modifierMasks[keyCode] else { return }
        let isDown = event.modifierFlags.rawValue & mask != 0
        if !isDown, keyCode == kVK_Command || keyCode == kVK_RightCommand {
            // AppKit never delivers keyUp for keys released while ⌘ is held: release them now.
            for scancode in pressedScancodes where !Self.modifierScancodes.contains(scancode) {
                pressedScancodes.remove(scancode)
                delegate?.displayView(self, send: .keyUp(scancode))
            }
        }
        if isDown, !pressedScancodes.contains(scancode) {
            pressedScancodes.insert(scancode)
            delegate?.displayView(self, send: .keyDown(scancode))
        } else if !isDown, pressedScancodes.contains(scancode) {
            pressedScancodes.remove(scancode)
            delegate?.displayView(self, send: .keyUp(scancode))
        }
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            delegate?.displayView(self, send: .capsLock(NSEvent.modifierFlags.contains(.capsLock)))
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        releaseAllInput()
        releasePointerLock()
        return super.resignFirstResponder()
    }

    @objc private func windowResignedKey(_ notification: Notification) {
        releaseAllInput()
        releasePointerLock()
    }

    /// Releases every key and button the guest believes is held (avoids stuck keys).
    func releaseAllInput() {
        for scancode in pressedScancodes {
            delegate?.displayView(self, send: .keyUp(scancode))
        }
        pressedScancodes.removeAll()
        for button in [MouseButton.left, .middle, .right, .side, .extra] where buttons.contains(MouseButtonMask(button: button)) {
            buttons.remove(MouseButtonMask(button: button))
            delegate?.displayView(self, send: .release(button, buttons: buttons))
        }
    }
}
