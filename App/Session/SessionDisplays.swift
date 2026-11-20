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

    init(owner: SessionController, primary: RemoteDisplayView, settings: AppSettings) {
        self.owner = owner; self.primary = primary; self.settings = settings
        sources[0] = Source(renderer: primary.renderer)
    }

    func handle(_ event: DisplayEvent, channel: UInt8) {
        guard !stopped, channel < SpiceSession.maxDisplays else { return }
        if sources[channel] == nil, let renderer = try? MetalRenderer() { sources[channel] = Source(renderer: renderer) }
        guard let source = sources[channel] else { return }
        switch event {
        case .primarySurfaceCreated(let id, let width, let height):
            source.surface = id
            source.renderer.createSurface(width: width, height: height)
            reconcile(channel: channel, source: source)
        case .primarySurfaceDestroyed(let id):
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

    /// A single-monitor payload disables other monitors. Until the full sparse,
    /// positioned resize contract is implemented, multi-head windows scale locally.
    var allowsLegacyResize: Bool {
        let ids = sources.values.flatMap { $0.layout?.heads.map(\.inputID) ?? [] }
        let contiguous = ids.sorted() == (0..<ids.count).map { UInt8($0) }
        return !sources.isEmpty && contiguous && Set(ids).count == ids.count &&
            windows.values.allSatisfy({ $0.window.isVisible && !$0.wasClosed }) && sources.values.allSatisfy { source in
            guard source.surface != nil, source.layout?.acceptsInput == true else { return false }
            guard let heads = source.advertised else { return true }
            return heads.count == 1 && heads[0].monitorID == 0 && heads[0].width > 0 && heads[0].height > 0
        }
    }

    var legacyViews: [UInt8: RemoteDisplayView] {
        var result: [UInt8: RemoteDisplayView] = [0: primary]
        for (key, window) in windows where key.channel > 0 && window.window.isVisible { result[key.channel] = window.view }
        return result
    }

    func stop() {
        stopped = true
        for view in allViews { view.stop() }
        for window in windows.values { window.close() }
        windows.removeAll()
        sources.removeAll()
    }
}
