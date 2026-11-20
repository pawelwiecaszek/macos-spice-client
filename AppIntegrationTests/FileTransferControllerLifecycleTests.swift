import Foundation
import SpiceKit
import Testing
@testable import SpiceClient

@MainActor
struct FileTransferControllerLifecycleTests {
    @Test func oldCompletionAndProgressCannotOverwriteReplacementTransfer() async throws {
        let sender = ControlledSender(), access = AccessLedger()
        let controller = makeController(sender: sender, access: access)
        controller.send([url("old")])
        let oldWorker = try #require(controller.worker)
        try await waitForRequests(sender, count: 1)
        controller.cancel()
        controller.send([url("new")])
        let newWorker = try #require(controller.worker)
        try await waitForRequests(sender, count: 2)
        await sender.report(0, sent: 99, total: 100)
        await sender.finish(0, result: .failure(SenderFailure.failed))
        await oldWorker.value
        #expect(controller.currentName == "new" && controller.worker != nil)
        #expect(controller.errorMessage == nil && controller.fraction == 0)
        await sender.report(1, sent: 50, total: 100)
        try await waitForFraction(controller, 0.5)
        await sender.finish(1)
        await newWorker.value
        #expect(controller.currentName == nil && controller.worker == nil && controller.queued == 0)
        #expect(access.stopped == [url("old"), url("new")])
    }

    @Test func cancelReleasesQueuedScopesButActiveScopeWaitsForSenderExit() async throws {
        let sender = ControlledSender(), access = AccessLedger()
        let controller = makeController(sender: sender, access: access)
        let files = [url("active"), url("queued1"), url("queued2")]
        controller.send(files)
        let worker = try #require(controller.worker)
        try await waitForRequests(sender, count: 1)
        #expect(controller.queued == 2)
        controller.cancel()
        #expect(access.stopped == Array(files.dropFirst()))
        #expect(controller.queued == 0 && controller.currentName == nil)
        await sender.finish(0, result: .failure(CancellationError()))
        await worker.value
        #expect(access.stopped == [files[1], files[2], files[0]])
        #expect(access.started == files)
        controller.cancel()
        #expect(access.stopped.count == 3)
    }

    @Test func readableFallbackNeverStopsAScopeItDidNotAcquire() async throws {
        let sender = ControlledSender(), access = AccessLedger(scoped: false)
        let controller = makeController(sender: sender, access: access)
        controller.send([url("readable")])
        let worker = try #require(controller.worker)
        try await waitForRequests(sender, count: 1)
        await sender.finish(0)
        await worker.value
        controller.cancel()
        #expect(access.started.count == 1 && access.stopped.isEmpty)
    }

    @Test func queuedResourcesStayBoundedAndAreReleasedExactlyOnce() async throws {
        let sender = ControlledSender(), access = AccessLedger()
        let controller = makeController(sender: sender, access: access)
        controller.send((0..<300).map { url("file-\($0)") })
        let worker = try #require(controller.worker)
        #expect(controller.queued == FileTransferController.maximumQueuedFiles)
        #expect(access.started.count == FileTransferController.maximumQueuedFiles)
        #expect(controller.errorMessage != nil)
        try await waitForRequests(sender, count: 1)
        controller.cancel()
        #expect(access.stopped.count == FileTransferController.maximumQueuedFiles - 1)
        await sender.finish(0, result: .failure(CancellationError()))
        await worker.value
        #expect(access.stopped.count == FileTransferController.maximumQueuedFiles)
        #expect(Set(access.stopped).count == access.stopped.count)
    }

    @Test func lateProgressFromPreviousFileCannotChangeNextFileInSameWorker() async throws {
        let sender = ControlledSender(), access = AccessLedger()
        let controller = makeController(sender: sender, access: access)
        controller.send([url("first"), url("second")])
        let worker = try #require(controller.worker)
        try await waitForRequests(sender, count: 1)
        await sender.finish(0)
        try await waitForRequests(sender, count: 2)
        await sender.report(0, sent: 100, total: 100)
        await sender.report(1, sent: 25, total: 100)
        try await waitForFraction(controller, 0.25)
        #expect(controller.currentName == "second")
        await sender.finish(1)
        await worker.value
        #expect(access.stopped == [url("first"), url("second")])
    }

    @Test func senderCancellationClearsRemainingQueueWithoutLeakingScopes() async throws {
        let sender = ControlledSender(), access = AccessLedger()
        let controller = makeController(sender: sender, access: access)
        controller.send([url("active"), url("queued")])
        let worker = try #require(controller.worker)
        try await waitForRequests(sender, count: 1)
        await sender.finish(0, result: .failure(CancellationError()))
        await worker.value
        #expect(controller.worker == nil && controller.currentName == nil && controller.queued == 0)
        #expect(Set(access.stopped) == Set(access.started) && access.stopped.count == 2)
    }

    private func makeController(sender: ControlledSender, access: AccessLedger) -> FileTransferController {
        FileTransferController(session: SpiceSession(profile: ConnectionProfile(host: "files.example.invalid")),
            sender: { url, progress in try await sender.send(url, progress: progress) },
            startAccess: { access.start($0) }, isReadable: { _ in true }, stopAccess: { access.stop($0) })
    }
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/private/tmp/spice-file-lifecycle/\(name)") }
    private func waitForRequests(_ sender: ControlledSender, count: Int) async throws {
        for _ in 0..<10_000 {
            if await sender.count == count { return }
            await Task.yield()
        }
        throw WaitFailure.timeout
    }
    private func waitForFraction(_ controller: FileTransferController, _ value: Double) async throws {
        for _ in 0..<10_000 {
            if controller.fraction == value { return }
            await Task.yield()
        }
        throw WaitFailure.timeout
    }
    private enum WaitFailure: Error { case timeout }
    private enum SenderFailure: Error { case failed }

    @MainActor
    private final class AccessLedger {
        let scoped: Bool
        var started: [URL] = []
        var stopped: [URL] = []
        init(scoped: Bool = true) { self.scoped = scoped }
        func start(_ url: URL) -> Bool { started.append(url); return scoped }
        func stop(_ url: URL) { stopped.append(url) }
    }
    private actor ControlledSender {
        private struct Request {
            let progress: @Sendable (Int64, Int64) -> Void
            var continuation: CheckedContinuation<Void, any Error>?
        }
        private var requests: [Request] = []
        var count: Int { requests.count }
        func send(_ url: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
            try await withCheckedThrowingContinuation { continuation in
                requests.append(Request(progress: progress, continuation: continuation))
            }
        }
        func report(_ index: Int, sent: Int64, total: Int64) { requests[index].progress(sent, total) }
        func finish(_ index: Int, result: Result<Void, any Error> = .success(())) {
            let continuation = requests[index].continuation
            requests[index].continuation = nil
            continuation?.resume(with: result)
        }
    }
}
