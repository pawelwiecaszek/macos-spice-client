import AppKit
import Observation
import SpiceKit

/// On-demand clipboard sharing. Unidentified replies are serialized: ownership
/// changes revoke writes but do not pretend to cancel an in-flight peer request.
@MainActor
final class ClipboardController {
    struct Transport: Sendable {
        let events: @Sendable () -> AsyncStream<AgentClipboardDelivery>
        let authorization: @Sendable () async -> ClipboardAgentAuthorization?
        let submit: @Sendable (AgentClipboardAction, ClipboardAgentAuthorization, ClipboardSharingAuthorization) async -> Bool
    }
    typealias ImageConverter = @Sendable (Data, Bool) async -> Data?
    private struct Pending {
        let id = UUID()
        let type: ClipboardDataType
        let authorization: ClipboardAgentAuthorization
        let changeCount: Int
        let deadline: ContinuousClock.Instant
        let receipt: ClipboardRequestReceipt
        var discard = false
    }
    private let settings: AppSettings
    private let pasteboard: NSPasteboard
    private let transport: Transport
    private let convertImage: ImageConverter
    private let now: @Sendable () -> ContinuousClock.Instant
    private let requestTimeout: Duration
    private let sharing = ClipboardSharingAuthority()
    private var tasks: [Task<Void, Never>] = []
    private var observers: [any NSObjectProtocol] = []
    private var imageTask: Task<Data?, Never>?
    private var imageIdentity: UUID?
    private var running = false
    private var stopped = false
    private var available = false
    private var wasActive = false
    private var revision: UInt64 = 0
    private var authorization: ClipboardAgentAuthorization?
    private var handledChangeCount: Int
    private var offeredTypes: [ClipboardDataType] = []
    private var offeredChangeCount = -1
    private var pending: Pending?
    private var deferredGrab: ([ClipboardDataType], ClipboardAgentAuthorization)?
    var isWindowActive: () -> Bool = { false }

    init(session: SpiceSession, settings: AppSettings, pasteboard: NSPasteboard = .general,
         transport: Transport? = nil, requestTimeout: Duration = .seconds(5),
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         imageConverter: @escaping ImageConverter = { data, requirePNG in
             await Task.detached(priority: .utility) { ClipboardImageCodec.encodePNG(data, requirePNG: requirePNG) }.value
         }) {
        self.settings = settings; self.pasteboard = pasteboard
        self.transport = transport ?? Transport(events: { session.clipboardEvents },
            authorization: { await session.clipboardAuthorization },
            submit: { action, authorization, sharing in
                await session.submitClipboard(action, authorization: authorization, sharing: sharing)
            })
        self.now = now; self.requestTimeout = max(.milliseconds(1), min(requestTimeout, .seconds(30)))
        self.convertImage = imageConverter
        handledChangeCount = pasteboard.changeCount
    }

    func start() {
        guard !running, !stopped else { return }
        running = true
        observeActivity()
        observePreference()
        let events = transport.events()
        tasks.append(Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
            if !Task.isCancelled { self?.stop() }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.poll()
            }
        })
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; running = false
        let previous = authorization
        let hadOffer = !offeredTypes.isEmpty
        revoke()
        for task in tasks { task.cancel() }
        tasks.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        imageTask?.cancel()
        if hadOffer, let previous, previous.isCurrent {
            let token = sharing.current, submit = transport.submit
            Task { _ = await submit(.release, previous, token) }
        }
    }

    func setAvailable(_ value: Bool) {
        guard available != value else { return }
        available = value
        revoke()
        if let pending, !pending.authorization.agent.isCurrent { self.pending = nil }
    }

    func activityDidChange() {
        let active = allowed
        if !active, wasActive { revoke() }
        wasActive = active
    }

    private var allowed: Bool { running && available && settings.shareClipboard && isWindowActive() }

    private func revoke() {
        revision &+= 1
        invalidatePendingRequest()
        sharing.invalidate()
        offeredTypes = []; offeredChangeCount = -1
        handledChangeCount = -1
        deferredGrab = nil
        wasActive = false
    }

    private func adopt(_ value: ClipboardAgentAuthorization) {
        guard authorization != value else { return }
        let oldAgent = authorization?.agent
        let previousCount = handledChangeCount
        let refreshHostOffer = !offeredTypes.isEmpty && authorization?.sharesClipboardOwnership(with: value) == true
        revoke()
        if oldAgent != value.agent { pending = nil }
        else if !refreshHostOffer {
            // A peer ownership change is not a new local copy. Polling can see
            // its wire token before the queued GRAB/RELEASE reaches the UI.
            handledChangeCount = previousCount
        }
        authorization = value
    }

    func poll() async {
        guard running else { return }
        activityDidChange()
        expireRequest()
        guard allowed else { return }
        let before = revision
        guard let current = await transport.authorization(), running, revision == before, allowed, current.isCurrent else { return }
        adopt(current)
        wasActive = true
        if pending == nil, imageTask == nil, let deferredGrab {
            self.deferredGrab = nil
            await request(deferredGrab.0, authorization: deferredGrab.1)
            return
        }
        let count = pasteboard.changeCount
        guard count != handledChangeCount else { return }
        // A new local copy takes ownership and invalidates a delayed guest write.
        invalidatePendingRequest(); deferredGrab = nil
        sharing.invalidate()
        let token = sharing.current
        let types = shareableTypes()
        offeredTypes = types; offeredChangeCount = count; handledChangeCount = count
        let accepted = await transport.submit(types.isEmpty ? .release : .offer(types), current, token)
        if !accepted, token.isCurrent { offeredTypes = []; offeredChangeCount = -1; handledChangeCount = -1 }
    }

    func handle(_ delivery: AgentClipboardDelivery) async {
        guard running else { return }
        guard delivery.authorization.isCurrent else {
            // A response decoded before renegotiation may still complete the
            // sole committed request. Drain it without writing or adopting its
            // obsolete negotiation; it cannot be mistaken for a fresh reply.
            if case .data(let selection, let type, _) = delivery.message,
               selection == .clipboard, let response = pending,
               response.receipt.status == .committed,
               response.authorization.agent == delivery.authorization.agent,
               delivery.authorization.agent.isCurrent,
               type == response.type || type == .none {
                pending = nil
                await requestDeferredIfPossible()
            }
            return
        }
        adopt(delivery.authorization)
        activityDidChange()
        expireRequest()
        switch delivery.message {
        case .grab(let selection, let types):
            guard selection == .clipboard else { return }
            invalidatePendingRequest()
            sharing.invalidate(); offeredTypes = []; offeredChangeCount = -1
            guard allowed else { pending?.discard = true; return }
            handledChangeCount = pasteboard.changeCount
            if pending != nil || imageTask != nil {
                pending?.discard = true
                deferredGrab = (types, delivery.authorization)
            } else { await request(types, authorization: delivery.authorization) }
        case .request(let selection, let type):
            guard selection == .clipboard else { return }
            await answer(type, authorization: delivery.authorization)
        case .data(let selection, let type, let bytes):
            guard selection == .clipboard, let response = pending, response.receipt.status == .committed,
                  response.authorization.agent == delivery.authorization.agent,
                  type == response.type || type == .none else { return }
            pending = nil
            if !response.discard, response.authorization.isCurrent, allowed,
               pasteboard.changeCount == response.changeCount, type == response.type,
               !bytes.isEmpty, bytes.count <= ClipboardCodec.maxDataSize {
                await write(type, bytes, response: response)
            }
            if running, pending == nil, imageTask == nil, let deferredGrab {
                self.deferredGrab = nil
                await request(deferredGrab.0, authorization: deferredGrab.1)
            }
        case .release(let selection):
            guard selection == .clipboard else { return }
            revision &+= 1; invalidatePendingRequest(); sharing.invalidate()
            deferredGrab = nil
            offeredTypes = []; offeredChangeCount = -1
        }
    }

    private func invalidatePendingRequest() {
        guard let response = pending else { return }
        if response.receipt.cancelIfUnsent() || response.receipt.status == .discarded { pending = nil }
        else { pending?.discard = true }
    }

    private func expireRequest() {
        if let pending, !pending.authorization.agent.isCurrent { self.pending = nil; deferredGrab = nil }
        else if let pending, pending.receipt.status == .discarded { self.pending = nil }
        else if let pending, now() >= pending.deadline { invalidatePendingRequest() }
    }

    private func requestDeferredIfPossible() async {
        guard running, allowed, pending == nil, imageTask == nil, let deferredGrab else { return }
        self.deferredGrab = nil
        await request(deferredGrab.0, authorization: deferredGrab.1)
    }

    private func request(_ types: [ClipboardDataType], authorization: ClipboardAgentAuthorization) async {
        guard allowed, authorization.isCurrent, pending == nil, imageTask == nil,
              let type = [ClipboardDataType.utf8Text, .png].first(where: types.contains) else { return }
        let token = sharing.requestAuthorization()
        guard let receipt = token.requestReceipt else { return }
        let response = Pending(type: type, authorization: authorization, changeCount: pasteboard.changeCount,
                               deadline: now().advanced(by: requestTimeout), receipt: receipt)
        pending = response
        let accepted = await transport.submit(.request(type), authorization, token)
        if !accepted, pending?.id == response.id { invalidatePendingRequest() }
    }

    private func shareableTypes() -> [ClipboardDataType] {
        let types = pasteboard.types ?? []
        return (types.contains(.string) ? [ClipboardDataType.utf8Text] : [])
            + (types.contains(.png) || types.contains(.tiff) ? [.png] : [])
    }

    private func answer(_ type: ClipboardDataType, authorization: ClipboardAgentAuthorization) async {
        let count = offeredChangeCount, token = sharing.current, before = revision
        var bytes: [UInt8] = []
        if allowed, offeredTypes.contains(type), pasteboard.changeCount == count {
            switch type {
            case .utf8Text:
                if let text = pasteboard.string(forType: .string), text.utf8.count <= ClipboardCodec.maxDataSize { bytes = Array(text.utf8) }
            case .png:
                if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
                   data.count <= ClipboardCodec.maxDataSize, let png = await image(data, requirePNG: false) { bytes = Array(png) }
            default: break
            }
        }
        guard running, authorization.isCurrent else { return }
        if !allowed || revision != before || !token.isCurrent || !offeredTypes.contains(type)
            || pasteboard.changeCount != count { bytes = [] }
        _ = await transport.submit(.provide(type, bytes), authorization, bytes.isEmpty ? sharing.current : token)
    }

    private func write(_ type: ClipboardDataType, _ bytes: [UInt8], response: Pending) async {
        let before = revision
        let token = sharing.current
        let png: Data?
        if type == .png { png = await image(Data(bytes), requirePNG: true); guard png != nil else { return } }
        else { png = nil }
        guard running, allowed, revision == before, token.isCurrent, response.authorization.isCurrent,
              pasteboard.changeCount == response.changeCount else { return }
        pasteboard.clearContents()
        if let png { pasteboard.setData(png, forType: .png) }
        else { pasteboard.setString(String(decoding: bytes, as: UTF8.self), forType: .string) }
        handledChangeCount = pasteboard.changeCount
        offeredTypes = []; offeredChangeCount = -1
    }

    private func image(_ data: Data, requirePNG: Bool) async -> Data? {
        guard imageTask == nil else { return nil }
        let identity = UUID(), converter = convertImage
        imageIdentity = identity
        let task = Task { await converter(data, requirePNG) }
        imageTask = task
        defer { if imageIdentity == identity { imageTask = nil; imageIdentity = nil } }
        return await task.value
    }

    private func observePreference() {
        let sharing = self.sharing
        withObservationTracking {
            _ = settings.shareClipboard
        } onChange: { [weak self, weak sharing] in
            // Observation fires at willSet. Revocation is synchronous and only
            // touches the Sendable authority, so queued DATA cannot start while
            // a main-actor cleanup callback is waiting to run.
            sharing?.invalidate()
            Task { @MainActor [weak self] in
                guard let self, self.running, !self.stopped else { return }
                self.revoke()
                self.observePreference()
            }
        }
    }

    private func observeActivity() {
        for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification,
                     NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.activityDidChange() }
            })
        }
    }
}
