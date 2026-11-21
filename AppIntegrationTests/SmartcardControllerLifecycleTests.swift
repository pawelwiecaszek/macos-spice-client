import Foundation
import SpiceKit
import Testing
@testable import SpiceClient

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SmartcardControllerLifecycleTests {
    @Test func unavailableReadersCardsAndPolicyNeverAcquireACard() async {
        let rig = Rig()
        let controller = rig.controller()
        controller.setChannelAvailable(true)
        await controller.refresh()
        #expect(controller.readers.isEmpty && controller.availabilityNote != nil)
        controller.share(rig.reader)
        rig.snapshotValue.readers = [.init(name: rig.reader.name, hasCard: false)]
        await controller.refresh()
        controller.share(rig.reader)
        #expect(rig.cardCalls == 0)
        rig.snapshotValue = .init(available: false, readers: [rig.reader])
        await controller.refresh()
        #expect(!controller.hostAvailable && !controller.canShare && controller.readers.isEmpty)
        #expect(controller.availabilityNote?.contains("unavailable") == true)
        controller.share(rig.reader)
        var profile = ConnectionProfile(host: "smartcard.example.invalid")
        profile.enableSmartcard = false
        let disabled = rig.controller(profile)
        disabled.setChannelAvailable(true)
        disabled.share(rig.reader)
        #expect(!disabled.isAvailable && rig.cardCalls == 0)
        controller.stop()
        disabled.stop()
    }

    @Test func pendingStopRollsBackWithoutLateStateOrCancellation() async throws {
        let rig = Rig()
        let controller = try await ready(rig)
        controller.share(rig.reader)
        let worker = try #require(controller.worker)
        try await wait { rig.requests.count == 1 }
        controller.stop()
        controller.start()
        rig.complete(0)
        await worker.value
        #expect(controller.stopped && !controller.isBusy && controller.sharedReader == nil)
        #expect(controller.restorableReader == nil && controller.errorMessage == nil)
        #expect(rig.removed == [rig.requests[0].id] && !rig.cancelledRequest)
    }

    @Test func pendingUnshareSuppressesLateFailureAndAllowsReplacement() async throws {
        let rig = Rig()
        let controller = try await ready(rig)
        controller.share(rig.reader)
        let old = try #require(controller.worker)
        try await wait { rig.requests.count == 1 }
        controller.unshare()
        controller.share(rig.reader)
        #expect(rig.cardCalls == 1 && controller.isBusy)
        rig.fail(0)
        await old.value
        #expect(controller.errorMessage == nil && !controller.isBusy)
        controller.share(rig.reader)
        let replacement = try #require(controller.worker)
        try await wait { rig.requests.count == 2 }
        rig.complete(1)
        await replacement.value
        #expect(controller.sharedReader == rig.reader.name)
        controller.stop()
        await controller.releaseWorker?.value
    }

    @Test func releaseReservesSharingAndOldEventsCannotClearReplacement() async throws {
        let rig = Rig()
        let controller = try await ready(rig)
        let oldID = try await share(controller, rig: rig, index: 0)
        rig.blockRemove = true
        controller.unshare()
        let release = try #require(controller.releaseWorker)
        try await wait { rig.removeWaiter != nil }
        controller.share(rig.reader)
        #expect(controller.isBusy && rig.cardCalls == 1 && controller.restorableReader == nil)
        rig.blockRemove = false
        rig.removeWaiter?.resume()
        rig.removeWaiter = nil
        await release.value
        _ = try await share(controller, rig: rig, index: 1)
        controller.handle(.removed)
        controller.handle(.attachmentRemoved(id: oldID))
        #expect(controller.sharedReader == rig.reader.name)
        controller.stop()
        await controller.releaseWorker?.value
    }

    @Test func earlyRemovalAndCardLossRevokePendingCompletion() async throws {
        let rig = Rig()
        let controller = try await ready(rig)
        controller.share(rig.reader)
        let first = try #require(controller.worker)
        try await wait { rig.requests.count == 1 }
        controller.handle(.attachmentRemoved(id: rig.requests[0].id))
        rig.complete(0)
        await first.value
        #expect(controller.sharedReader == nil && controller.errorMessage == nil)
        controller.share(rig.reader)
        let second = try #require(controller.worker)
        try await wait { rig.requests.count == 2 }
        rig.snapshotValue.readers = []
        await controller.refresh()
        rig.complete(1)
        await second.value
        #expect(controller.sharedReader == nil && controller.restorableReader == nil)
        #expect(rig.removed.count == 2)
        controller.stop()
    }

    @Test func stoppedRefreshAndCancelledRestoreCannotPublishOrAcquire() async throws {
        let rig = Rig()
        let controller = try await ready(rig)
        rig.holdSnapshot = true
        let refresh = Task { await controller.refresh() }
        try await wait { rig.snapshotWaiter != nil }
        controller.stop()
        rig.snapshotWaiter?.resume(returning: .init(available: false))
        rig.snapshotWaiter = nil
        await refresh.value
        #expect(controller.hostAvailable && controller.readers == [rig.reader])
        let restore = Task { await controller.restore(readerName: rig.reader.name) }
        restore.cancel()
        await restore.value
        #expect(rig.cardCalls == 0)
    }

    @Test func fallbackTracksAttachmentIdentityAndRespectsSlotCapacity() async throws {
        let rig = Rig()
        let controller = rig.controller()
        rig.snapshotValue.readers = [rig.reader]
        await controller.refresh()
        controller.share(rig.reader)
        #expect(rig.cardCalls == 0 && !controller.isAvailable)
        rig.usb.setSlotCount(1)
        await controller.refresh()
        controller.share(rig.reader)
        let worker = try #require(controller.worker)
        try await wait { rig.requests.count == 1 }
        #expect(!rig.requests[0].usesChannel)
        rig.complete(0)
        await worker.value
        let oldID = rig.requests[0].id
        rig.current.remove(oldID) // A replacement now occupies the old slot.
        await controller.refresh()
        await controller.releaseWorker?.value
        #expect(controller.sharedReader == nil && rig.removed == [oldID])
        controller.stop()
    }

    private func ready(_ rig: Rig) async throws -> SmartcardController {
        let controller = rig.controller()
        controller.setChannelAvailable(true)
        rig.snapshotValue.readers = [rig.reader]
        await controller.refresh()
        return controller
    }

    private func share(_ controller: SmartcardController, rig: Rig, index: Int) async throws -> UUID {
        controller.share(rig.reader)
        let worker = try #require(controller.worker)
        try await wait { rig.requests.count == index + 1 }
        rig.complete(index)
        await worker.value
        return rig.requests[index].id
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        throw FixtureError.timeout
    }
    private enum FixtureError: Error { case timeout, refused }

    @MainActor
    private final class Rig {
        struct Request {
            let id: UUID
            let usesChannel: Bool
            let continuation: CheckedContinuation<SmartcardController.Attachment, any Error>
        }
        let reader = SmartcardReaderInfo(name: "Simulated reader", hasCard: true)
        let usb: USBController
        var snapshotValue = SmartcardController.ReaderSnapshot()
        var requests: [Request] = []
        var current: Set<UUID> = []
        var removed: [UUID] = []
        var cardCalls = 0
        var cancelledRequest = false
        var blockRemove = false, holdSnapshot = false
        var removeWaiter: CheckedContinuation<Void, Never>?
        var snapshotWaiter: CheckedContinuation<SmartcardController.ReaderSnapshot, Never>?

        init() {
            let profile = ConnectionProfile(host: "smartcard.example.invalid")
            usb = USBController(session: SpiceSession(profile: profile), profile: profile,
                environment: .init(attach: { _, _, _ in throw FixtureError.refused },
                    devices: { [] }, startInventory: {}))
        }

        func controller(_ profile: ConnectionProfile = ConnectionProfile(host: "smartcard.example.invalid")) -> SmartcardController {
            SmartcardController(session: SpiceSession(profile: profile), usb: usb,
                environment: .init(readers: { [self] in await snapshot() },
                    card: { [self] _ in cardCalls += 1; return SimulatedCard() },
                    insert: { [self] _, id in try await request(id: id, usesChannel: true) },
                    insertUSB: { [self] _, _, id in try await request(id: id, usesChannel: false) }))
        }
        func snapshot() async -> SmartcardController.ReaderSnapshot {
            if holdSnapshot { return await withCheckedContinuation { snapshotWaiter = $0 } }
            return snapshotValue
        }
        func request(id: UUID, usesChannel: Bool) async throws -> SmartcardController.Attachment {
            let result = try await withCheckedThrowingContinuation { requests.append(Request(id: id, usesChannel: usesChannel, continuation: $0)) }
            cancelledRequest = cancelledRequest || Task.isCancelled
            return result
        }
        func complete(_ index: Int) {
            let request = requests[index]
            current.insert(request.id)
            request.continuation.resume(returning: .init(id: request.id, usesChannel: request.usesChannel,
                isCurrent: { [self] in current.contains(request.id) },
                remove: { [self] in
                    removed.append(request.id)
                    if blockRemove { await withCheckedContinuation { removeWaiter = $0 } }
                    current.remove(request.id)
                }))
        }
        func fail(_ index: Int) { requests[index].continuation.resume(throwing: FixtureError.refused) }
    }
}

private actor SimulatedCard: SmartcardCard, CCIDCard {
    nonisolated let displayName = "Simulated card"
    func connect() async throws -> [UInt8] { [0x3B, 0] }
    func transmit(_ apdu: [UInt8]) async throws -> [UInt8] { [0x90, 0] }
    func disconnect() async {}
}
