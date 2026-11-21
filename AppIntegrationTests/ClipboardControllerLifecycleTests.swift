import AppKit
import ImageIO
import SpiceKit
import Synchronization
import Testing
@testable import SpiceClient

@MainActor
struct ClipboardControllerLifecycleTests {
    @Test func textRoundTripUsesOnlyTheOfferedUnchangedPasteboard() async throws {
        let fixture = makeFixture(); defer { fixture.close() }
        fixture.board.setString("Mac text", forType: .string)
        await fixture.controller.poll()
        #expect(await fixture.probe.actions == [.offer([.utf8Text])])
        await fixture.deliver(.request(selection: .clipboard, type: .utf8Text))
        #expect(await fixture.probe.actions.last == .provide(.utf8Text, Array("Mac text".utf8)))
        fixture.board.clearContents(); fixture.board.setString("new local text", forType: .string)
        await fixture.deliver(.request(selection: .clipboard, type: .utf8Text))
        #expect(await fixture.probe.actions.last == .provide(.utf8Text, []))
        await fixture.deliver(.grab(selection: .clipboard, types: [.utf8Text]))
        await fixture.deliver(.data(selection: .clipboard, type: .utf8Text, bytes: Array("Guest text".utf8)))
        #expect(fixture.board.string(forType: .string) == "Guest text")
    }

    @Test func localCopyWinsOverAnOutstandingGuestReply() async {
        let fixture = makeFixture(); defer { fixture.close() }
        fixture.board.setString("before", forType: .string)
        await fixture.deliver(.grab(selection: .clipboard, types: [.utf8Text]))
        fixture.board.clearContents(); fixture.board.setString("local wins", forType: .string)
        await fixture.deliver(.data(selection: .clipboard, type: .utf8Text, bytes: Array("stale guest".utf8)))
        #expect(fixture.board.string(forType: .string) == "local wins")
    }

    @Test func newerGrabWaitsForTheOldReplyWithoutWritingIt() async {
        let fixture = makeFixture(); defer { fixture.close() }
        fixture.board.setString("original", forType: .string)
        await fixture.deliver(.grab(selection: .clipboard, types: [.utf8Text]))
        await fixture.deliver(.grab(selection: .clipboard, types: [.utf8Text]))
        #expect(await fixture.probe.requestCount == 1)
        await fixture.deliver(.data(selection: .clipboard, type: .utf8Text, bytes: Array("old response".utf8)))
        #expect(fixture.board.string(forType: .string) == "original")
        #expect(await fixture.probe.requestCount == 2)
        await fixture.deliver(.data(selection: .clipboard, type: .utf8Text, bytes: Array("latest response".utf8)))
        #expect(fixture.board.string(forType: .string) == "latest response")
    }

    @Test func releaseAndTimeoutAreNotReplyDrainFences() async {
        let clock = ManualTime()
        let fixture = makeFixture(now: { clock.now }); defer { fixture.close() }
        fixture.board.setString("keep", forType: .string)
        await fixture.deliver(.grab(selection: .clipboard, types: [.utf8Text]))
        await fixture.deliver(.release(selection: .clipboard))
        clock.advance(.seconds(6))
        await fixture.controller.poll()
        await fixture.deliver(.grab(selection: .clipboard, types: [.utf8Text]))
        #expect(await fixture.probe.requestCount == 1)
        await fixture.deliver(.data(selection: .clipboard, type: .utf8Text, bytes: Array("expired".utf8)))
        #expect(fixture.board.string(forType: .string) == "keep")
        #expect(await fixture.probe.requestCount == 2)
    }

    @Test func emptyAndNoneResponsesCompleteOnlyThePendingRequest() async {
        for type in [ClipboardDataType.none, .utf8Text] {
            let fixture = makeFixture(); defer { fixture.close() }
            fixture.board.setString("keep", forType: .string)
            await fixture.deliver(.grab(selection: .clipboard, types: [.utf8Text]))
            await fixture.deliver(.grab(selection: .clipboard, types: [.utf8Text]))
            await fixture.deliver(.data(selection: .clipboard, type: type, bytes: []))
            #expect(await fixture.probe.requestCount == 2)
            #expect(fixture.board.string(forType: .string) == "keep")
            await fixture.deliver(.data(selection: .clipboard, type: .utf8Text, bytes: Array("new".utf8)))
            #expect(fixture.board.string(forType: .string) == "new")
        }
    }

    @Test func disabledInactiveAndStoppedControllersCannotLeakOrWriteClipboard() async {
        let fixture = makeFixture(); defer { fixture.close() }
        fixture.board.setString("private", forType: .string)
        await fixture.controller.poll()
        let offered = await fixture.probe.lastSharing
        fixture.active.value = false; fixture.controller.activityDidChange()
        #expect(offered?.isCurrent == false)
        await fixture.deliver(.request(selection: .clipboard, type: .utf8Text))
        #expect(await fixture.probe.actions.last == .provide(.utf8Text, []))
        await fixture.deliver(.grab(selection: .clipboard, types: [.utf8Text]))
        #expect(await fixture.probe.requestCount == 0)
        fixture.active.value = true
        fixture.settings.shareClipboard = false
        await fixture.controller.poll()
        await fixture.deliver(.grab(selection: .clipboard, types: [.utf8Text]))
        #expect(await fixture.probe.requestCount == 0)
        fixture.settings.shareClipboard = true
        await fixture.deliver(.grab(selection: .clipboard, types: [.utf8Text]))
        fixture.controller.stop()
        await fixture.deliver(.data(selection: .clipboard, type: .utf8Text, bytes: Array("late".utf8)))
        fixture.controller.start(); await fixture.controller.poll()
        #expect(fixture.board.string(forType: .string) == "private")
        #expect(await fixture.probe.requestCount == 1)
    }

    @Test func preferenceFlipRevokesQueuedSharingBeforeAnyAsyncCleanup() async throws {
        let fixture = makeFixture(); defer { fixture.close() }
        fixture.board.setString("private", forType: .string)
        await fixture.controller.poll()
        let offered = try #require(await fixture.probe.lastSharing)
        #expect(offered.isCurrent)
        fixture.settings.shareClipboard = false
        #expect(!offered.isCurrent, "Preference willSet must retire queued DATA synchronously")
        fixture.controller.stop()
        fixture.settings.shareClipboard = true
        await fixture.controller.poll()
        #expect(!offered.isCurrent, "Stopping cannot rearm the old sharing lifetime")
    }

    @Test func unsentFocusLossRetiresTheReceiptAndAllowsANewRequest() async throws {
        let fixture = makeFixture(); defer { fixture.close() }
        fixture.board.setString("keep", forType: .string)
        await fixture.probe.setRequestsQueued(true)
        await fixture.deliver(.grab(selection: .clipboard, types: [.utf8Text]))
        let queued = try #require(await fixture.probe.lastSharing?.requestReceipt)
        #expect(queued.status == .queued)
        // No request byte was committed, so a matching unsolicited DATA cannot
        // satisfy the pending request or overwrite the pasteboard.
        await fixture.deliver(.data(selection: .clipboard, type: .utf8Text, bytes: Array("unsolicited".utf8)))
        #expect(fixture.board.string(forType: .string) == "keep")
        fixture.active.value = false; fixture.controller.activityDidChange()
        #expect(queued.status == .discarded && !queued.tryCommit())
        fixture.active.value = true
        await fixture.probe.setRequestsQueued(false)
        await fixture.deliver(.grab(selection: .clipboard, types: [.utf8Text]))
        #expect(await fixture.probe.requestCount == 2)
        await fixture.deliver(.data(selection: .clipboard, type: .utf8Text, bytes: Array("fresh".utf8)))
        #expect(fixture.board.string(forType: .string) == "fresh")
    }

    @Test func agentReplacementRetiresRepliesButNegotiationChangesKeepTheDrainBarrier() async {
        let fixture = makeFixture(); defer { fixture.close() }
        fixture.board.setString("keep", forType: .string)
        await fixture.deliver(.grab(selection: .clipboard, types: [.utf8Text]))
        let oldNegotiation = await fixture.probe.authorization
        await fixture.probe.changeNegotiation()
        await fixture.deliver(.grab(selection: .clipboard, types: [.utf8Text]))
        #expect(await fixture.probe.requestCount == 1)
        await fixture.controller.handle(.init(message: .data(selection: .clipboard, type: .utf8Text, bytes: Array("old".utf8)), authorization: oldNegotiation))
        #expect(fixture.board.string(forType: .string) == "keep")
        #expect(await fixture.probe.requestCount == 2)
        let previous = await fixture.probe.authorization
        await fixture.probe.changeAgent()
        fixture.controller.setAvailable(false); fixture.controller.setAvailable(true)
        await fixture.controller.handle(.init(message: .data(selection: .clipboard, type: .utf8Text, bytes: Array("retired".utf8)), authorization: previous))
        await fixture.deliver(.grab(selection: .clipboard, types: [.utf8Text]))
        await fixture.deliver(.data(selection: .clipboard, type: .utf8Text, bytes: Array("fresh".utf8)))
        #expect(fixture.board.string(forType: .string) == "fresh")
    }

    @Test func pngAndTiffConversionUseAnIsolatedBoardAndRejectInvalidHeaders() async throws {
        let fixture = makeFixture(); defer { fixture.close() }
        let png = try imageData(type: "public.png"), tiff = try imageData(type: "public.tiff")
        fixture.board.setData(tiff, forType: .tiff)
        await fixture.controller.poll()
        await fixture.deliver(.request(selection: .clipboard, type: .png))
        let action = await fixture.probe.actions.last
        guard case .provide(.png, let bytes) = action else { Issue.record("Expected PNG conversion"); return }
        #expect(!bytes.isEmpty)
        let converted = try #require(CGImageSourceCreateWithData(Data(bytes) as CFData, nil))
        #expect(CGImageSourceGetType(converted) as String? == "public.png")
        await fixture.deliver(.grab(selection: .clipboard, types: [.png]))
        await fixture.deliver(.data(selection: .clipboard, type: .png, bytes: Array(png)))
        #expect(fixture.board.data(forType: .png) != nil)
        let before = fixture.board.changeCount
        await fixture.deliver(.grab(selection: .clipboard, types: [.png]))
        await fixture.deliver(.data(selection: .clipboard, type: .png, bytes: Array(tiff)))
        #expect(fixture.board.changeCount == before, "A guest-declared PNG cannot smuggle a TIFF")
        await fixture.deliver(.grab(selection: .clipboard, types: [.png]))
        await fixture.deliver(.data(selection: .clipboard, type: .png, bytes: [0, 1, 2]))
        #expect(fixture.board.changeCount == before)
        #expect(ClipboardImageCodec.acceptsDimensions(width: 8192, height: 8192))
        #expect(!ClipboardImageCodec.acceptsDimensions(width: Int.max, height: Int.max))
        #expect(!ClipboardImageCodec.acceptsDimensions(width: 8193, height: 8192))
    }

    @Test func releaseDuringImageConversionPreventsLateWriteAndOnlyOneImageJobRuns() async throws {
        let gate = ImageGate()
        let fixture = makeFixture(converter: { bytes, _ in await gate.convert(bytes) }); defer { fixture.close() }
        fixture.board.setString("keep", forType: .string)
        await fixture.deliver(.grab(selection: .clipboard, types: [.png]))
        let conversion = Task { await fixture.deliver(.data(selection: .clipboard, type: .png, bytes: [1])) }
        try await waitForImage(gate)
        await fixture.deliver(.release(selection: .clipboard))
        await fixture.deliver(.grab(selection: .clipboard, types: [.png]))
        #expect(await fixture.probe.requestCount == 1)
        #expect(await gate.calls == 1)
        await gate.finish(Data([1]))
        await conversion.value
        #expect(fixture.board.string(forType: .string) == "keep")
        #expect(await fixture.probe.requestCount == 2)
    }

    @Test func wireOwnershipChangeDuringImageConversionRejectsTheOldImageBeforeUIEventDelivery() async throws {
        let gate = ImageGate(passthroughAfterFirst: true)
        let fixture = makeFixture(converter: { bytes, _ in await gate.convert(bytes) }); defer { fixture.close() }
        let png = try imageData(type: "public.png")
        fixture.board.setString("new local value", forType: .string)
        await fixture.deliver(.grab(selection: .clipboard, types: [.png]))
        let oldConversion = Task { await fixture.deliver(.data(selection: .clipboard, type: .png, bytes: Array(png))) }
        try await waitForImage(gate)
        // Main has read a new GRAB/RELEASE, but the controller's event loop is
        // still waiting for conversion and has not consumed that metadata yet.
        await fixture.probe.changeOwnership()
        let beforePolling = await fixture.probe.actions
        await fixture.controller.poll()
        let afterPolling = await fixture.probe.actions
        #expect(afterPolling == beforePolling, "A wire ownership change must not re-offer stale Mac contents while conversion blocks the UI event loop")
        await gate.finish(png)
        await oldConversion.value
        #expect(fixture.board.string(forType: .string) == "new local value")
        #expect(fixture.board.data(forType: .png) == nil)
        await fixture.deliver(.grab(selection: .clipboard, types: [.png]))
        await fixture.deliver(.data(selection: .clipboard, type: .png, bytes: Array(png)))
        #expect(fixture.board.data(forType: .png) == png)
        #expect(await fixture.probe.requestCount == 2)
    }

    @Test func peerReleaseDoesNotEchoItsOldClipboardBackWithoutANewLocalCopy() async {
        let fixture = makeFixture(); defer { fixture.close() }
        await fixture.deliver(.grab(selection: .clipboard, types: [.utf8Text]))
        await fixture.deliver(.data(selection: .clipboard, type: .utf8Text, bytes: Array("guest".utf8)))
        for _ in 0..<3 {
            await fixture.probe.changeOwnership()
            await fixture.deliver(.release(selection: .clipboard))
            await fixture.controller.poll()
        }
        let released = await fixture.probe.actions
        #expect(!released.contains { if case .offer = $0 { true } else { false } })
        fixture.board.clearContents()
        fixture.board.setString("new local copy", forType: .string)
        await fixture.controller.poll()
        let copied = await fixture.probe.actions
        #expect(copied.last == .offer([.utf8Text]))
    }

    private func makeFixture(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                             converter: ClipboardController.ImageConverter? = nil) -> Fixture {
        let board = NSPasteboard(name: .init("clipboard-lifecycle-\(UUID())"))
        let settings = AppSettings(persistChanges: false); settings.shareClipboard = true
        let probe = Probe(), active = ActiveWindow()
        let transport = ClipboardController.Transport(events: { probe.events }, authorization: { await probe.authorization },
            submit: { action, authorization, sharing in await probe.submit(action, authorization: authorization, sharing: sharing) })
        let session = SpiceSession(profile: ConnectionProfile(host: "clipboard.example.invalid"))
        let controller: ClipboardController
        if let converter { controller = ClipboardController(session: session, settings: settings, pasteboard: board, transport: transport, now: now, imageConverter: converter) }
        else { controller = ClipboardController(session: session, settings: settings, pasteboard: board, transport: transport, now: now) }
        controller.isWindowActive = { active.value }
        controller.start(); controller.setAvailable(true)
        return Fixture(board: board, settings: settings, probe: probe, active: active, controller: controller)
    }
    @MainActor
    private struct Fixture {
        let board: NSPasteboard
        let settings: AppSettings
        let probe: Probe
        let active: ActiveWindow
        let controller: ClipboardController
        func close() { controller.stop(); board.releaseGlobally() }
        func deliver(_ message: ClipboardMessage) async {
            await controller.handle(.init(message: message, authorization: await probe.authorization))
        }
    }
    private final class ActiveWindow { var value = true }
    private final class ManualTime: Sendable {
        private let value = Mutex(ContinuousClock.now)
        var now: ContinuousClock.Instant { value.withLock { $0 } }
        func advance(_ duration: Duration) { value.withLock { $0 = $0.advanced(by: duration) } }
    }
    private actor Probe {
        nonisolated let events: AsyncStream<AgentClipboardDelivery>
        private let sink: AsyncStream<AgentClipboardDelivery>.Continuation
        private let agent = AgentAuthorizationSource(), negotiation = AgentAuthorizationSource(), ownership = AgentAuthorizationSource()
        var actions: [AgentClipboardAction] = []
        var lastSharing: ClipboardSharingAuthorization?
        private var requestsStayQueued = false
        var authorization: ClipboardAgentAuthorization { .init(agent: agent.current, negotiation: negotiation.current, ownership: ownership.current) }
        var requestCount: Int { actions.filter { if case .request = $0 { true } else { false } }.count }
        init() { (events, sink) = AsyncStream.makeStream() }
        func submit(_ action: AgentClipboardAction, authorization: ClipboardAgentAuthorization, sharing: ClipboardSharingAuthorization) -> Bool {
            guard authorization.isCurrent, sharing.isCurrent else { return false }
            if case .request = action, !requestsStayQueued {
                guard sharing.requestReceipt?.tryCommit() == true else { return false }
            }
            actions.append(action); lastSharing = sharing
            return true
        }
        func setRequestsQueued(_ value: Bool) { requestsStayQueued = value }
        func changeAgent() { agent.advance(); negotiation.advance(); ownership.advance() }
        func changeOwnership() { ownership.advance() }
        func changeNegotiation() { negotiation.advance() }
    }
    private actor ImageGate {
        private var waiter: CheckedContinuation<Data?, Never>?
        private(set) var calls = 0
        private let passthroughAfterFirst: Bool
        init(passthroughAfterFirst: Bool = false) { self.passthroughAfterFirst = passthroughAfterFirst }
        func convert(_ bytes: Data) async -> Data? {
            calls += 1
            if passthroughAfterFirst, calls > 1 { return bytes }
            return await withCheckedContinuation { waiter = $0 }
        }
        func finish(_ bytes: Data?) { waiter?.resume(returning: bytes); waiter = nil }
    }
    private func waitForImage(_ gate: ImageGate) async throws {
        for _ in 0..<10_000 { if await gate.calls == 1 { return }; await Task.yield() }
        throw WaitFailure.timeout
    }
    private enum WaitFailure: Error { case timeout }
    private func imageData(type: String) throws -> Data {
        let pixels = Data([20, 40, 60, 255])
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
