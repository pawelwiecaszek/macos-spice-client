import AppKit
import Observation
import SpiceKit
import os

/// Glue between one `SpiceSession` and its window: consumes session streams on the main
/// actor, feeds the renderer, and forwards input from the display view.
@MainActor
@Observable
final class SessionController: RemoteDisplayViewDelegate {
    enum Phase: Equatable {
        case connecting
        case connected
        /// The connection dropped; another attempt follows (M8).
        case reconnecting(ReconnectProgress)
        case ended(String?)
    }

    struct ReconnectProgress: Equatable {
        var attempt: Int
        var maxAttempts: Int
        /// Waiting for the Mac to get a network connection back.
        var waitingForNetwork = false
        /// When the next attempt starts (`nil`: starting now).
        var retryAt: Date?
    }

    /// Why the last session ended, for the ended screen.
    enum EndKind: Equatable {
        case networkLost
        case serverEnded
        case authentication
        case vmNotRunning
        case failed
    }

    let id = UUID()
    let profile: ConnectionProfile
    private(set) var phase: Phase = .connecting
    private(set) var title: String
    private(set) var clientMouseMode = true
    private(set) var agentConnected = false
    private(set) var isAuthenticationFailure = false
    private(set) var endKind: EndKind = .failed
    /// This session is itself an attempt to reconnect a dropped one.
    let reconnect: ReconnectContext?

    let usb: USBController
    /// The Proxmox VM behind this session, when the `.vv` came from Proxmox.
    let vmRef: ProxmoxVMRef?
    var powerError: String?
    private(set) var powerBusy = false
    let smartcard: SmartcardController
    @ObservationIgnored let clipboard: ClipboardController
    let audio: AudioController
    let files: FileTransferController
    @ObservationIgnored let displayView: RemoteDisplayView?
    @ObservationIgnored private let session: SpiceSession
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    /// Windows of additional guest monitors, by SPICE display id (M6 groundwork).
    @ObservationIgnored private var secondaryWindows: [UInt8: SecondaryDisplayWindow] = [:]
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let log = Logger(subsystem: "com.pawelwiecaszek.spiceclient", category: "session")
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private let policy = ReconnectPolicy()
    /// The original profile had no ticket, so it can simply be used again.
    @ObservationIgnored private let reusableProfile: Bool
    @ObservationIgnored private var connectedAt: Date?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?

    init(profile: ConnectionProfile, settings: AppSettings = .shared, reconnect: ReconnectContext? = nil) {
        self.profile = profile
        self.settings = settings
        self.reconnect = reconnect
        reusableProfile = profile.password == nil
        self.title = profile.displayTitle
        self.vmRef = ProxmoxVMRef(profile: profile)
        let session = SpiceSession(profile: profile)
        self.session = session
        self.usb = USBController(session: session, profile: profile)
        self.smartcard = SmartcardController(session: session, usb: usb)
        self.clipboard = ClipboardController(session: session, settings: settings)
        self.audio = AudioController(session: session, settings: settings)
        self.files = FileTransferController(session: session)
        if let renderer = try? MetalRenderer() {
            displayView = RemoteDisplayView(renderer: renderer)
        } else {
            displayView = nil
        }
        displayView?.hotkeys = HotkeyMatcher(profile: profile)
        displayView?.sendsCommandToGuest = settings.sendCommandKeyToGuest
        displayView?.delegate = self
        displayView?.setAccessibilityLabel(String(localized: "Screen of \(profile.displayTitle)"))
        if displayView == nil { phase = .ended(String(localized: "Metal is not available on this Mac.")) }
        clipboard.isWindowActive = { [weak self] in
            guard let window = self?.window else { return false }
            return window.isKeyWindow && NSApp.isActive
        }
    }

    func start() {
        guard displayView != nil else { return }
        let session = self.session
        tasks.append(Task { [weak self] in
            for await event in session.events { self?.handle(event) }
        })
        tasks.append(Task { [weak self] in
            for await event in session.displayEvents { self?.handle(event) }
        })
        tasks.append(Task { [weak self] in
            for await event in session.cursorEvents { self?.handle(event) }
        })
        tasks.append(Task { [weak self] in
            for await event in session.secondaryDisplayEvents { self?.handle(event) }
        })
        usb.start()
        smartcard.start()
        clipboard.start()
        audio.start()
        let audioSupport = audio.support
        tasks.append(Task {
            await session.configureAudio(audioSupport)
            await session.connect()
        })
    }

    // MARK: Proxmox power control

    /// A server with an API token is configured for this session's VM.
    var canControlPower: Bool {
        guard let vmRef else { return false }
        return ProxmoxStore.shared.server(forHost: vmRef.apiHost) != nil
    }

    func power(_ action: ProxmoxPowerAction) {
        guard let vmRef, !powerBusy, ProxmoxStore.confirm(action, vmName: title) else { return }
        powerBusy = true
        Task {
            defer { powerBusy = false }
            do {
                try await ProxmoxStore.shared.perform(action, on: vmRef)
            } catch {
                powerError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Starts the VM if it is off, then opens a fresh session and closes this window.
    /// Starts (or resumes) the VM if needed, then reconnects in this window.
    func startAndReconnect() {
        guard let vmRef, !powerBusy, let server = ProxmoxStore.shared.server(forHost: vmRef.apiHost) else { return }
        powerBusy = true
        Task {
            defer { powerBusy = false }
            do {
                let client = try ProxmoxStore.shared.client(for: server)
                let status = try await client.status(node: vmRef.node, vmid: vmRef.vmid)
                if status != "running" {
                    try await client.perform(status == "paused" ? .resume : .start, node: vmRef.node, vmid: vmRef.vmid)
                    for _ in 0..<60 where try await client.status(node: vmRef.node, vmid: vmRef.vmid) != "running" {
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                reconnectNow()
            } catch {
                powerError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func stop() {
        reconnectTask?.cancel()
        restoreTask?.cancel()
        displayView?.stop()
        for window in secondaryWindows.values { window.close() }
        secondaryWindows.removeAll()
        usb.stop()
        smartcard.stop()
        clipboard.stop()
        audio.stop()
        files.cancel()
        let session = self.session
        Task { await session.disconnect() }
        resizeTask?.cancel()
    }

    // MARK: Reconnect (M8)

    /// The session can be reconnected without the user fetching a new connection file:
    /// Proxmox hands out fresh tickets through the API, and ticket-less servers take the
    /// same settings again. One-time tickets from a downloaded `.vv` are wiped after use.
    var canReconnect: Bool {
        if vmRef != nil, canControlPower { return true }
        return reusableProfile
    }

    /// The last failure, kept for the ended screen when reconnecting is cancelled.
    @ObservationIgnored private var lastFailureMessage: String?
    @ObservationIgnored private var reconnectCancelled = false

    private func sessionEnded(_ failure: SessionFailure?) {
        guard !reconnectCancelled else { return }
        isAuthenticationFailure = failure?.isAuthenticationFailure ?? false
        lastFailureMessage = failure?.message
        endKind = Self.kind(of: failure)
        guard let failure else {
            phase = .ended(nil)
            return
        }
        let wasConnected = connectedAt != nil
        let stable = connectedAt.map { Date.now.timeIntervalSince($0) >= Double(policy.stableAfter.components.seconds) } ?? false
        // A reconnection that didn't stay up continues the count; anything else starts over.
        let attempt = if let reconnect, !stable { reconnect.attempt + 1 } else { 1 }
        if settings.reconnectAutomatically, canReconnect,
           policy.shouldReconnect(after: failure, wasConnected: wasConnected, reconnecting: reconnect != nil && !stable),
           policy.delay(beforeAttempt: attempt) != nil {
            if wasConnected { announce(String(localized: "Connection to \(title) lost. Reconnecting.")) }
            scheduleReconnect(attempt: attempt, carry: currentCarryOver())
        } else {
            phase = .ended(failure.message)
            announce(String(localized: "Connection to \(title) ended. \(failure.message)"))
        }
    }

    private static func kind(of failure: SessionFailure?) -> EndKind {
        guard let failure else { return .serverEnded }
        if failure.isAuthenticationFailure { return .authentication }
        return switch failure.recovery {
        case .automatic: .networkLost
        case .manual: .serverEnded
        case .none: .failed
        }
    }

    /// Waits for the network and the back-off delay, then makes the attempt.
    private func scheduleReconnect(attempt: Int, carry: SessionCarryOver) {
        guard let delay = policy.delay(beforeAttempt: attempt) else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            var progress = ReconnectProgress(attempt: attempt, maxAttempts: self?.policy.delays.count ?? 0)
            if !NetworkMonitor.shared.isOnline {
                progress.waitingForNetwork = true
                self?.phase = .reconnecting(progress)
                await NetworkMonitor.shared.waitUntilOnline()
                progress.waitingForNetwork = false
            }
            guard !Task.isCancelled else { return }
            progress.retryAt = Date.now.addingTimeInterval(Double(delay.components.seconds))
            self?.phase = .reconnecting(progress)
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.attemptReconnect(attempt: attempt, carry: carry)
        }
    }

    /// Reconnects right away: the Reconnect button, "Try Now", and after starting the VM.
    func reconnectNow() {
        let attempt = if case .reconnecting(let progress) = phase { progress.attempt } else { 1 }
        let carry = currentCarryOver()
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            await self?.attemptReconnect(attempt: attempt, carry: carry)
        }
    }

    var maxReconnectAttempts: Int { policy.delays.count }

    /// Stops reconnecting and shows why the session ended.
    func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        if phase == .connecting {
            // This session is the attempt: abandon it quietly.
            reconnectCancelled = true
            let session = self.session
            Task { await session.disconnect() }
        }
        if reconnect != nil, connectedAt == nil { endKind = .networkLost }
        phase = .ended(lastFailureMessage ?? reconnect?.lastFailure)
    }

    private func attemptReconnect(attempt: Int, carry: SessionCarryOver) async {
        phase = .reconnecting(ReconnectProgress(attempt: attempt, maxAttempts: policy.delays.count))
        let next: ConnectionProfile
        do {
            if let vmRef, canControlPower {
                next = try await ProxmoxStore.shared.reconnectProfile(for: vmRef)
            } else if reusableProfile {
                next = profile
            } else {
                throw ProxmoxStore.ReconnectError.noAPIAccess
            }
        } catch ProxmoxStore.ReconnectError.notRunning(let status) {
            endKind = .vmNotRunning
            phase = .ended(status == "paused"
                ? String(localized: "The virtual machine is paused.")
                : String(localized: "The virtual machine isn’t running."))
            return
        } catch {
            guard !Task.isCancelled else { return }
            // The Proxmox API didn't answer either: count it as a failed attempt.
            let message = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            lastFailureMessage = message
            if settings.reconnectAutomatically, policy.delay(beforeAttempt: attempt + 1) != nil {
                scheduleReconnect(attempt: attempt + 1, carry: carry)
            } else {
                endKind = .networkLost
                phase = .ended(message)
            }
            return
        }
        guard !Task.isCancelled else { return }
        let context = ReconnectContext(attempt: attempt, carryOver: carry,
                                       lastFailure: lastFailureMessage ?? reconnect?.lastFailure)
        SessionWindowManager.shared.replace(self, with: next, context: context)
    }

    /// What to bring back after reconnecting: shared devices, discs, card, microphone.
    private func currentCarryOver() -> SessionCarryOver {
        guard connectedAt != nil else { return reconnect?.carryOver ?? SessionCarryOver() }
        return SessionCarryOver(usbDevices: usb.restorableDeviceIDs, isos: usb.restorableISOs,
                                smartcardReader: smartcard.restorableReader,
                                microphone: audio.microphoneEnabled)
    }

    private func restoreCarryOver() {
        guard let carry = reconnect?.carryOver, !carry.isEmpty else { return }
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            if carry.microphone { self?.audio.restoreMicrophone() }
            guard !carry.usbDevices.isEmpty || !carry.isos.isEmpty || carry.smartcardReader != nil else { return }
            // usbredir slots and the smartcard channel are announced shortly after connecting.
            for _ in 0..<20 {
                guard let self, self.phase == .connected else { return }
                if self.usb.slotCount > 0 || self.smartcard.isAvailable { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let self, self.phase == .connected else { return }
            self.usb.restore(deviceIDs: carry.usbDevices, isos: carry.isos)
            if let reader = carry.smartcardReader {
                // Leave the USB devices a moment to take their slots first.
                try? await Task.sleep(for: .seconds(1))
                await self.smartcard.restore(readerName: reader)
            }
        }
    }

    private func announce(_ text: String) {
        let element: Any = window.map { $0 as Any } ?? NSApplication.shared
        NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    // MARK: Session streams

    private func handle(_ event: SessionEvent) {
        switch event {
        case .state(.connecting):
            phase = .connecting
        case .state(.connected):
            phase = .connected
            connectedAt = .now
            session.send(.capsLock(NSEvent.modifierFlags.contains(.capsLock)))
            if reconnect != nil { announce(String(localized: "Reconnected to \(title)")) }
            restoreCarryOver()
        case .state(.disconnected(let failure)):
            displayView?.stop()
            sessionEnded(failure)
        case .state(.idle):
            break
        case .mouseMode(let mode):
            clientMouseMode = mode.contains(.client)
            displayView?.clientMouseMode = clientMouseMode
            for window in secondaryWindows.values { window.view.clientMouseMode = clientMouseMode }
        case .agentConnected(let connected):
            agentConnected = connected
            if connected { scheduleGuestResize() }
        case .usbSlots(let count):
            usb.setSlotCount(count)
        case .smartcardAvailable(let available):
            smartcard.setChannelAvailable(available)
        case .clipboardAvailable(let available):
            clipboard.setAvailable(available)
        case .guestName(let name):
            if profile.title?.isEmpty ?? true { title = name }
        }
    }

    private func handle(_ event: DisplayEvent) {
        // Return the update credit even if nothing is drawn (applying is synchronous).
        defer { if case .update = event { session.displayCredit.consumed() } }
        guard let view = displayView else { return }
        switch event {
        case .primarySurfaceCreated(_, let width, let height):
            view.renderer.createSurface(width: width, height: height)
            adjustWindow(toGuestWidth: width, height: height)
        case .primarySurfaceDestroyed:
            view.renderer.destroySurface()
        case .update(let update):
            view.renderer.apply(update)
        case .monitorsConfig:
            break
        }
    }

    private func handle(_ event: SecondaryDisplayEvent) {
        let id = event.display
        defer {
            if case .update = event.event, Int(id) >= 1, Int(id) <= session.secondaryDisplayCredits.count {
                session.secondaryDisplayCredits[Int(id) - 1].consumed()
            }
        }
        switch event.event {
        case .primarySurfaceCreated(_, let width, let height):
            if secondaryWindows[id] == nil {
                guard let window = SecondaryDisplayWindow(display: id, owner: self, title: title, settings: settings) else { return }
                window.view.clientMouseMode = clientMouseMode
                secondaryWindows[id] = window
            }
            secondaryWindows[id]?.show(width: width, height: height)
        case .primarySurfaceDestroyed:
            secondaryWindows.removeValue(forKey: id)?.close()
        case .update(let update):
            secondaryWindows[id]?.view.renderer.apply(update)
        case .monitorsConfig:
            break
        }
    }

    private func handle(_ event: CursorEvent) {
        guard let view = displayView else { return }
        switch event {
        case .shape(let image):
            view.setGuestCursor(image)
        case .move(let x, let y):
            view.renderer.cursorPosition = SIMD2(Float(x), Float(y))
        case .visible(let visible):
            view.guestCursorVisible = visible
            view.renderer.showsCursorOverlay = visible && !clientMouseMode
        case .reset:
            view.setGuestCursor(nil)
        }
    }

    // MARK: Actions

    func sendCtrlAltDelete() {
        for (code, down) in Keymap.ctrlAltDelete {
            session.send(down ? .keyDown(code) : .keyUp(code))
        }
    }

    func releaseCursor() {
        displayView?.releasePointerLock()
        displayView?.releaseAllInput()
    }

    func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }

    // MARK: RemoteDisplayViewDelegate

    func displayView(_ view: RemoteDisplayView, send event: InputEvent) {
        guard phase == .connected else { return }
        session.send(event)
    }

    func displayView(_ view: RemoteDisplayView, perform action: HotkeyAction) {
        switch action {
        case .toggleFullscreen: toggleFullscreen()
        case .releaseCursor: releaseCursor()
        case .secureAttention: sendCtrlAltDelete()
        }
    }

    func displayView(_ view: RemoteDisplayView, didResizeTo pixelSize: CGSize) {
        scheduleGuestResize()
    }

    func displayView(_ view: RemoteDisplayView, didDropFiles urls: [URL]) {
        guard phase == .connected else { return }
        files.send(urls)
    }

    // MARK: Window / guest size

    /// Debounced (~300 ms) request for the guest to match the window size (needs vdagent).
    private func scheduleGuestResize() {
        guard settings.resizeGuestWithWindow, agentConnected, let view = displayView else { return }
        resizeTask?.cancel()
        let session = self.session
        let retina = settings.useRetinaResolution
        // Even widths are friendlier to guest drivers.
        func guestSize(_ view: RemoteDisplayView) -> (width: Int, height: Int) {
            let scale = retina ? (view.window?.backingScaleFactor ?? 2) : 1
            return (Int(view.bounds.width * scale) & ~1, Int(view.bounds.height * scale))
        }
        var sizes: [UInt8: (width: Int, height: Int)] = [0: guestSize(view)]
        for (id, window) in secondaryWindows where window.window.isVisible { sizes[id] = guestSize(window.view) }
        resizeTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await session.requestGuestMonitors(sizes)
        }
    }

    /// Sizes the window to the guest (1 guest pixel = 1 point, or 1 pixel in Retina mode)
    /// unless it is fullscreen or the guest follows the window size instead.
    private func adjustWindow(toGuestWidth width: Int, height: Int) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        // After a reconnect the window keeps the size the user had.
        guard reconnect == nil else { return }
        guard !settings.resizeGuestWithWindow || !agentConnected else { return }
        let scale = settings.useRetinaResolution ? window.backingScaleFactor : 1
        var content = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        if let screen = window.screen?.visibleFrame.size {
            let fit = min(1, min(screen.width / content.width, (screen.height - 60) / content.height))
            content = NSSize(width: content.width * fit, height: content.height * fit)
        }
        window.setContentSize(content)
    }
}

/// Carried from a dropped session to the one that replaces it in the same window.
struct ReconnectContext {
    var attempt: Int
    var carryOver: SessionCarryOver
    /// Why the original session dropped (shown if reconnecting is cancelled).
    var lastFailure: String?
}

/// What the user had shared with the guest when the connection dropped.
struct SessionCarryOver: Equatable {
    var usbDevices: [UInt64] = []
    var isos: [URL] = []
    var smartcardReader: String?
    var microphone = false

    var isEmpty: Bool { usbDevices.isEmpty && isos.isEmpty && smartcardReader == nil && !microphone }
}
