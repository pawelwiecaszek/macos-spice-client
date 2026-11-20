import AppKit
import SpiceKit

/// One texture owner per display channel; head windows borrow that texture.
@MainActor
final class SessionDisplays {
    struct Key: Hashable { let channel: UInt8; let head: UInt32 }
    private final class Source {
        let renderer: MetalRenderer
        var surface: UInt32?
        var advertised: [MonitorHead]?
        var layout: MonitorLayout?
        var authorization: MonitorResizeAuthorization?
        var awaitingTopology = false
        init(renderer: MetalRenderer) { self.renderer = renderer }
    }
    private weak var owner: SessionController?
    private let primary: RemoteDisplayView
    private let settings: AppSettings
    private var sources: [UInt8: Source] = [:]
    private(set) var windows: [Key: SecondaryDisplayWindow] = [:]
    private var stopped = false
    private var cursor: CursorImage?
    private var cursorPosition = SIMD2<Float>(0, 0)
    private var cursorVisible = true
    private var clientMouseMode = true
    private var expectedChannels: Set<UInt8>?
    private(set) var resizeRevision: UInt64 = 0
    private var requestedLayout: GuestMonitorLayout?
    private var monitorConfigurationSupport: [UInt8: Bool] = [:]
    private let resizeIntentAuthority = MonitorResizeAuthority()
    private var resizeIntentAuthorization: MonitorResizeAuthorization?
    private var mainAuthorization: MonitorResizeAuthorization?
    private var awaitingMainTopology = true

    init(owner: SessionController, primary: RemoteDisplayView, settings: AppSettings) {
        self.owner = owner; self.primary = primary; self.settings = settings
        sources[0] = Source(renderer: primary.renderer)
        resizeIntentAuthorization = resizeIntentAuthority.advance()
    }

    func handle(_ event: DisplayEvent, channel: UInt8) {
        guard !stopped, channel < SpiceSession.maxDisplays else { return }
        if case .update = event { } else { invalidateResizeIntent() }
        if sources[channel] == nil, let renderer = try? MetalRenderer() { sources[channel] = Source(renderer: renderer) }
        guard let source = sources[channel] else { return }
        switch event {
        case .topologyAuthorization(let authorization):
            source.authorization = authorization
            source.awaitingTopology = true
        case .primarySurfaceCreated(let id, let width, let height):
            source.awaitingTopology = false
            source.surface = id
            source.renderer.createSurface(width: width, height: height)
            reconcile(channel: channel, source: source)
        case .primarySurfaceDestroyed(let id):
            source.awaitingTopology = false
            guard source.surface == id else { return }
            source.surface = nil; source.advertised = nil; source.layout = nil
            source.renderer.destroySurface()
            closeWindows(channel: channel)
            if channel == 0 {
                primary.releasePointerLock(); primary.releaseAllInput()
                primary.acceptsGuestInput = false
            }
            refreshInputAdmission()
        case .update(let update):
            guard update.surfaceID == source.surface else { return }
            source.renderer.apply(update)
            for (key, window) in windows where key.channel == channel { window.view.renderer.setNeedsDisplay() }
        case .monitorsConfig(let heads):
            source.awaitingTopology = false
            source.advertised = heads
            reconcile(channel: channel, source: source)
        }
    }

    private func reconcile(channel: UInt8, source: Source) {
        guard let surface = source.surface, let owner else { return }
        let size = source.renderer.surfaceSize
        let layout = MonitorLayout(channel: channel, surface: surface, width: size.width, height: size.height,
                                   advertised: source.advertised)
        source.layout = layout
        let mainHead = channel == 0 ? layout.heads.first : nil
        let extra = layout.heads.filter { channel != 0 || $0.id != mainHead?.id }
        let wanted = Set(extra.map { Key(channel: channel, head: $0.id) })
        for key in Array(windows.keys) where key.channel == channel && !wanted.contains(key) {
            windows.removeValue(forKey: key)?.close()
        }
        if channel == 0 {
            primary.releasePointerLock()
            primary.releaseAllInput()
            primary.acceptsGuestInput = layout.acceptsInput
            primary.displayID = mainHead?.inputID ?? 0
            source.renderer.sourceRect = mainHead?.crop ?? (mainHead == nil ? .zero : nil)
            applyCursor(to: primary, channel: 0)
            if let head = mainHead { owner.adjustWindow(toGuestWidth: Int(head.size.width), height: Int(head.size.height)) }
        }
        for head in extra {
            let key = Key(channel: channel, head: head.id)
            if windows[key]?.wasClosed == true { windows.removeValue(forKey: key)?.close() }
            if windows[key] == nil {
                windows[key] = SecondaryDisplayWindow(display: head.inputID, owner: owner, title: owner.title, settings: settings)
            }
            guard let window = windows[key] else { continue }
            window.view.releasePointerLock()
            window.view.releaseAllInput()
            window.view.acceptsGuestInput = layout.acceptsInput
            window.view.renderer.adoptSurface(from: source.renderer)
            window.view.renderer.sourceRect = head.crop
            applyCursor(to: window.view, channel: channel)
            window.showHead(width: Int(head.size.width), height: Int(head.size.height), retina: settings.useRetinaResolution)
        }
        refreshInputAdmission()
    }

    private func refreshInputAdmission() {
        let ids = sources.values.flatMap { $0.layout?.heads.map(\.inputID) ?? [] }
        func admitted(_ id: UInt8, source: Source?) -> Bool {
            source?.layout?.acceptsInput == true && ids.filter { $0 == id }.count == 1
        }
        let primaryAllowed = admitted(primary.displayID, source: sources[0])
        if primary.acceptsGuestInput && !primaryAllowed { primary.releasePointerLock(); primary.releaseAllInput() }
        primary.acceptsGuestInput = primaryAllowed
        for (key, window) in windows {
            let allowed = admitted(window.view.displayID, source: sources[key.channel])
            if window.view.acceptsGuestInput && !allowed { window.view.releasePointerLock(); window.view.releaseAllInput() }
            window.view.acceptsGuestInput = allowed
        }
        let unsupported = sources.values.contains { $0.layout?.acceptsInput == false && $0.layout?.heads.isEmpty == false }
        owner?.displayNotice = unsupported || Set(ids).count != ids.count ?
            String(localized: "This monitor layout is view-only. Guest input is unavailable for unsupported or ambiguous monitor mappings.") : nil
    }

    private func closeWindows(channel: UInt8) {
        for key in Array(windows.keys) where key.channel == channel { windows.removeValue(forKey: key)?.close() }
    }

    func setMouseMode(_ client: Bool) {
        clientMouseMode = client
        primary.clientMouseMode = client
        for (key, window) in windows {
            window.view.clientMouseMode = client
            window.view.renderer.showsCursorOverlay = key.channel == 0 && cursorVisible && !client
        }
    }

    func handle(_ event: CursorEvent) {
        switch event {
        case .shape(let image): cursor = image
        case .move(let x, let y): cursorPosition = SIMD2(Float(x), Float(y))
        case .visible(let visible): cursorVisible = visible
        case .reset: cursor = nil
        }
        func update(_ view: RemoteDisplayView, channel: UInt8) {
            switch event {
            case .shape, .reset: view.setGuestCursor(cursor)
            case .move: view.renderer.cursorPosition = cursorPosition
            case .visible:
                view.guestCursorVisible = cursorVisible
                view.renderer.showsCursorOverlay = channel == 0 && cursorVisible && !clientMouseMode
            }
        }
        update(primary, channel: 0)
        for (key, window) in windows { update(window.view, channel: key.channel) }
    }

    private func applyCursor(to view: RemoteDisplayView, channel: UInt8) {
        view.clientMouseMode = clientMouseMode
        view.setGuestCursor(cursor)
        view.guestCursorVisible = cursorVisible
        view.renderer.cursorPosition = cursorPosition
        // The session's cursor stream currently lacks a display-channel identity.
        view.renderer.showsCursorOverlay = channel == 0 && cursorVisible && !clientMouseMode
    }

    var allViews: [RemoteDisplayView] { [primary] + windows.values.map(\.view) }

    func expectChannels(_ channels: [UInt8]) {
        expectedChannels = Set(channels)
        awaitingMainTopology = false
        invalidateResizeIntent()
    }

    func setMainAuthorization(_ authorization: MonitorResizeAuthorization) {
        mainAuthorization = authorization
        awaitingMainTopology = true
        invalidateResizeIntent()
    }

    func agentLifecycleObserved() {
        awaitingMainTopology = false
        invalidateResizeIntent()
    }

    func invalidateResizeIntent() {
        resizeRevision &+= 1
        requestedLayout = nil
        retirePendingResize()
    }

    func retirePendingResize() { resizeIntentAuthorization = resizeIntentAuthority.advance() }

    func setMonitorConfigurationSupport(channel: UInt8, supported: Bool) {
        monitorConfigurationSupport[channel] = supported
        invalidateResizeIntent()
    }

    var resizeAuthorizations: [MonitorResizeAuthorization]? {
        guard let expectedChannels, let intent = resizeIntentAuthorization,
              !awaitingMainTopology, let main = mainAuthorization else { return nil }
        var values = [intent, main]
        for channel in expectedChannels.sorted() {
            guard let source = sources[channel], !source.awaitingTopology, let authorization = source.authorization else { return nil }
            values.append(authorization)
        }
        return values.allSatisfy(\.isCurrent) ? values : nil
    }

    /// Keeps the complete known set, including disabled and closed-window heads.
    /// Unknown peers/layouts refuse the request instead of disabling unseen heads.
    func prepareResize(of view: RemoteDisplayView, width: Int, height: Int) -> GuestMonitorLayout? {
        guard !stopped, view.acceptsGuestInput, (2...16_384).contains(width), (1...16_384).contains(height),
              resizeAuthorizations != nil,
              let expectedChannels, !expectedChannels.isEmpty, expectedChannels.contains(0),
              expectedChannels.allSatisfy({ $0 < SpiceSession.maxDisplays && sources[$0] != nil }) else { return nil }
        let target: UInt8
        if view === primary {
            guard let id = sources[0]?.layout?.heads.first?.inputID else { return nil }
            target = id
        } else {
            guard let window = windows.values.first(where: { $0.view === view }), !window.wasClosed else { return nil }
            target = view.displayID
        }
        var monitors: [GuestMonitor] = []
        let legacy = expectedChannels.allSatisfy { sources[$0]?.advertised == nil }
        var legacyX: Int64 = 0
        for channel in expectedChannels.sorted() {
            guard let source = sources[channel] else { return nil }
            if let advertised = source.advertised {
                guard !advertised.isEmpty, channel == 0 || (advertised.count == 1 && advertised[0].monitorID == 0) else { return nil }
                for head in advertised {
                    let enabled = head.width > 0 && head.height > 0
                    guard let id = UInt8(exactly: head.monitorID),
                          !enabled || (source.surface != nil && source.layout?.acceptsInput == true),
                          let x = Int32(exactly: enabled ? head.x : 0),
                          let y = Int32(exactly: enabled ? head.y : 0) else { return nil }
                    monitors.append(GuestMonitor(id: channel == 0 ? id : channel,
                        width: enabled ? head.width : 0, height: enabled ? head.height : 0, x: x, y: y))
                }
            } else {
                guard legacy, monitorConfigurationSupport[channel] == false,
                      source.surface != nil, source.layout?.acceptsInput == true,
                      let x = Int32(exactly: legacyX) else { return nil }
                let size = source.renderer.surfaceSize
                monitors.append(GuestMonitor(id: channel, width: UInt32(size.width), height: UInt32(size.height), x: x, y: 0))
                legacyX += Int64(size.width)
            }
        }
        guard let known = GuestMonitorLayout(monitors),
              let resized = (requestedLayout ?? known).resizing(id: target, width: UInt32(width & ~1), height: UInt32(height)),
              fitsSurfaceBudgets(resized, channels: expectedChannels) else { return nil }
        requestedLayout = resized
        retirePendingResize()
        return resized
    }

    private func fitsSurfaceBudgets(_ layout: GuestMonitorLayout, channels: Set<UInt8>) -> Bool {
        for channel in channels {
            let ids: Set<UInt8>
            if channel == 0, let advertised = sources[channel]?.advertised {
                ids = Set(advertised.compactMap { UInt8(exactly: $0.monitorID) })
            } else { ids = [channel] }
            let active = layout.monitors.filter { ids.contains($0.id) && $0.width > 0 && $0.height > 0 }
            guard !active.isEmpty else { continue }
            let width: Int64, height: Int64
            if active.count == 1, let head = active.first {
                width = Int64(head.width); height = Int64(head.height)
            } else {
                width = active.map { Int64($0.x) + Int64($0.width) }.max() ?? 0
                height = active.map { Int64($0.y) + Int64($0.height) }.max() ?? 0
            }
            guard width > 0, height > 0, width <= 16_384, height <= 16_384,
                  width * height <= 128 * 1024 * 1024 else { return false }
        }
        return true
    }

    func stop() {
        stopped = true
        invalidateResizeIntent()
        for view in allViews { view.stop() }
        for window in windows.values { window.close() }
        windows.removeAll()
        sources.removeAll()
    }
}
