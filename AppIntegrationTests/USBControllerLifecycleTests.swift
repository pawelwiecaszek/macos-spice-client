import Foundation
import SpiceKit
import Observation
import Synchronization
import Testing
@testable import SpiceClient

@MainActor
struct USBControllerLifecycleTests {
    @Test func pendingAttachmentReservesSlotAndStopRollsBackWithoutPublishing() async throws {
        let rig = Rig()
        let controller = rig.controller()
        controller.setSlotCount(1)
        controller.mountISO(rig.url)
        let worker = try #require(controller.workers.values.first)
        controller.mountISO(rig.url)
        controller.redirect(rig.host(1))
        #expect(controller.freeSlots == 0 && controller.mountingISO)
        try await wait { rig.requests.count == 1 }
        #expect(rig.imageCalls == 1 && rig.hostCalls == 0)
        controller.stop()
        controller.start()
        rig.complete(0, slot: 0)
        _ = try? await worker.value
        #expect(controller.attached.isEmpty && controller.errorMessage == nil)
        #expect(rig.detached == [rig.requests[0].id])
        #expect(rig.started == [rig.url] && rig.stopped == [rig.url])
        #expect(controller.freeSlots == 0)
    }

    @Test func failureReleasesScopeAndPermitsAnotherMount() async throws {
        let rig = Rig()
        let controller = rig.controller()
        controller.setSlotCount(1)
        controller.mountISO(rig.url)
        let worker = try #require(controller.workers.values.first)
        try await wait { rig.requests.count == 1 }
        rig.requests[0].continuation.resume(throwing: USBAttachError.guestNotReady)
        _ = try? await worker.value
        #expect(controller.errorMessage != nil && !controller.mountingISO && controller.freeSlots == 1)
        #expect(rig.stopped == [rig.url])
        controller.mountISO(rig.url)
        let replacement = try #require(controller.workers.values.first)
        try await wait { rig.requests.count == 2 }
        rig.complete(1, slot: 0)
        _ = try await replacement.value
        #expect(controller.mountedISO != nil && rig.stopped.count == 1)
        controller.detach(slot: 0)
        try await wait { rig.stopped.count == 2 }
    }

    @Test func oldEjectAndDetachEventCannotRemoveReplacementAtSameURL() async throws {
        let rig = Rig()
        let controller = rig.controller()
        controller.setSlotCount(2)
        let oldID = try await mount(controller, rig: rig, index: 0, slot: 0)
        controller.detach(slot: 0)
        try await wait { controller.freeSlots == 2 }
        let newID = try await mount(controller, rig: rig, index: 1, slot: 0)
        rig.ejects[0]()
        controller.handle(.attachmentEnded(slot: 0, attachmentID: oldID, reason: .deviceGone))
        await Task.yield()
        #expect(controller.mountedISO?.id == newID)
        #expect(rig.detached == [oldID])
        controller.stop()
        try await wait { rig.detached.count == 2 }
    }

    @Test func detachKeepsDuplicateAndScopeReservedUntilDeviceIsClosed() async throws {
        let rig = Rig()
        rig.blockDetach = true
        let controller = rig.controller()
        controller.setSlotCount(2)
        _ = try await mount(controller, rig: rig, index: 0, slot: 0)
        controller.detach(slot: 0)
        try await wait { rig.detachWaiter != nil }
        controller.mountISO(rig.url)
        controller.mountISO(URL(fileURLWithPath: "/private/tmp/another.iso"))
        #expect(controller.mountingISO && rig.imageCalls == 1 && rig.stopped.isEmpty)
        rig.detachWaiter?.resume()
        rig.detachWaiter = nil
        try await wait { !controller.mountingISO }
        #expect(rig.stopped == [rig.url])
    }

    @Test func earlyGuestRejectionCannotPublishGhostAttachment() async throws {
        let rig = Rig()
        let controller = rig.controller()
        controller.setSlotCount(1)
        controller.mountISO(rig.url)
        let worker = try #require(controller.workers.values.first)
        try await wait { rig.requests.count == 1 }
        controller.handle(.attachmentEnded(slot: 0, attachmentID: rig.requests[0].id, reason: .guestRejected))
        rig.complete(0, slot: 0)
        _ = try? await worker.value
        #expect(controller.attached.isEmpty && controller.errorMessage != nil)
        #expect(rig.detached.count == 1 && rig.stopped == [rig.url])
    }

    @Test func unavailableDevicesAreRejectedBeforeFactoryOrSlotCapture() async throws {
        let rig = Rig()
        var profile = ConnectionProfile(host: "usb.example.invalid")
        profile.enableSmartcard = false
        let controller = rig.controller(profile)
        controller.setSlotCount(2)
        var claimed = rig.host(1)
        claimed.claimedByMacOS = true
        let hub = rig.host(2, usbClass: 9), card = rig.host(3, usbClass: 11)
        for device in [claimed, hub, card] {
            #expect(controller.unavailableReason(device) != nil)
            controller.redirect(device, confirmed: true)
        }
        #expect(rig.hostCalls == 0 && controller.freeSlots == 2 && controller.workers.isEmpty)
        profile.enableUSBRedirection = false
        let disabled = rig.controller(profile)
        disabled.setSlotCount(2)
        disabled.mountISO(rig.url)
        disabled.redirect(rig.host(4))
        #expect(disabled.freeSlots == 0 && rig.started.isEmpty && rig.hostCalls == 0)
    }

    @Test func duplicateHostDoesNotCaptureTwiceAndReadableFallbackDoesNotReleaseUnacquiredScope() async throws {
        let rig = Rig()
        rig.scopeGranted = false
        let controller = rig.controller()
        controller.setSlotCount(2)
        controller.redirect(rig.host(1))
        let hostWorker = try #require(controller.workers.values.first)
        controller.redirect(rig.host(1))
        try await wait { rig.requests.count == 1 }
        #expect(rig.hostCalls == 1 && controller.busyDeviceIDs == [1])
        rig.complete(0, slot: 0)
        _ = try await hostWorker.value
        controller.mountISO(rig.url)
        let imageWorker = try #require(controller.workers.values.first)
        try await wait { rig.requests.count == 2 }
        rig.complete(1, slot: 1)
        _ = try await imageWorker.value
        controller.stop()
        try await wait { rig.detached.count == 2 }
        #expect(rig.stopped.isEmpty)
    }

    @Test func slotReservationAndReleaseNotifyAvailabilityObservers() async throws {
        let rig = Rig()
        let controller = rig.controller()
        controller.setSlotCount(1)
        let reserved = Mutex(false)
        withObservationTracking { _ = controller.freeSlots } onChange: { reserved.withLock { $0 = true } }
        controller.redirect(rig.host(1))
        let worker = try #require(controller.workers.values.first)
        #expect(reserved.withLock { $0 } && controller.freeSlots == 0)
        try await wait { rig.requests.count == 1 }
        rig.complete(0, slot: 0)
        _ = try await worker.value
        let released = Mutex(false)
        withObservationTracking { _ = controller.freeSlots } onChange: { released.withLock { $0 = true } }
        controller.detach(slot: 0)
        try await wait { controller.freeSlots == 1 }
        #expect(released.withLock { $0 })
    }

    private func mount(_ controller: USBController, rig: Rig, index: Int, slot: Int) async throws -> UUID {
        controller.mountISO(rig.url)
        let worker = try #require(controller.workers.values.first)
        try await wait { rig.requests.count == index + 1 }
        rig.complete(index, slot: slot)
        _ = try await worker.value
        return rig.requests[index].id
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        throw WaitFailure.timeout
    }
    private enum WaitFailure: Error { case timeout }

    @MainActor
    private final class Rig {
        struct Request {
            var id: UUID
            var continuation: CheckedContinuation<USBController.Attachment, any Error>
        }
        let url = URL(fileURLWithPath: "/private/tmp/controller-lifetime.iso")
        var requests: [Request] = []
        var detached: [UUID] = []
        var imageCalls = 0, hostCalls = 0
        var started: [URL] = [], stopped: [URL] = []
        var scopeGranted = true, blockDetach = false
        var detachWaiter: CheckedContinuation<Void, Never>?
        var ejects: [@Sendable () -> Void] = []

        func controller(_ profile: ConnectionProfile = ConnectionProfile(host: "usb.example.invalid")) -> USBController {
            USBController(session: SpiceSession(profile: profile), profile: profile,
                environment: .init(attach: { [self] _, _, id in try await attach(id) },
                    hostDevice: { [self] _ in hostCalls += 1; return drive() },
                    image: { [self] _, eject in imageCalls += 1; ejects.append(eject); return drive() },
                    devices: { [] }, startInventory: {},
                    startAccess: { [self] url in started.append(url); return scopeGranted },
                    stopAccess: { [self] url in stopped.append(url) }))
        }
        func host(_ id: UInt64, usbClass: UInt8 = 255) -> HostUSBDevice {
            HostUSBDevice(id: id, name: "USB \(id)", descriptor: .init(classes: [usbClass], vendorID: 1, productID: 2, deviceVersion: 0))
        }
        func drive() -> EmulatedCDROM { EmulatedCDROM(source: MemoryBlockSource(bytes: [UInt8](repeating: 0, count: 2048)), name: "test") }
        func attach(_ id: UUID) async throws -> USBController.Attachment {
            try await withCheckedThrowingContinuation { requests.append(Request(id: id, continuation: $0)) }
        }
        func complete(_ index: Int, slot: Int) {
            let id = requests[index].id
            requests[index].continuation.resume(returning: .init(slot: slot, id: id, detach: { [self] in await detach(id) }))
        }
        func detach(_ id: UUID) async {
            detached.append(id)
            if blockDetach { await withCheckedContinuation { detachWaiter = $0 } }
        }
    }
}
