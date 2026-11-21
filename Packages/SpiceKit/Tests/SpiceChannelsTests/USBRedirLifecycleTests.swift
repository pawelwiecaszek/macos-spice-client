import Foundation
import Synchronization
import Testing
@testable import SpiceChannels
import SpiceTransport
import SpiceWire
import USBRedirWire

/// Suspends a chosen send even if close arrives, exercising the post-send guard.
private actor PausedUSBStream: SpiceByteStream {
    let base: MemoryByteStream
    private var sends = 0
    private var pauseAt: Int?
    private var suspended: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var failingSend: Int?
    nonisolated let cancelledSend = Mutex(false)

    init(_ base: MemoryByteStream) { self.base = base }
    func pause(send: Int) { pauseAt = send }
    func fail(send: Int) { failingSend = send }
    func waitForPause() async {
        if suspended != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func resume() {
        suspended?.resume()
        suspended = nil
    }
    func send(_ bytes: [UInt8]) async throws {
        let base = self.base
        try await withTaskCancellationHandler {
            try await performSend(bytes)
        } onCancel: {
            cancelledSend.withLock { $0 = true }
            Task { await base.close() }
        }
    }
    private func performSend(_ bytes: [UInt8]) async throws {
        sends += 1
        let currentSend = sends
        if currentSend == failingSend { throw TransportError.closed }
        try await base.send(bytes)
        if currentSend == pauseAt {
            await withCheckedContinuation { continuation in
                suspended = continuation
                for observer in observers { observer.resume() }
                observers.removeAll()
            }
        }
    }
    func receive(exactly count: Int) async throws -> [UInt8] { try await base.receive(exactly: count) }
    func close() async { await base.close() }
}

private actor CompletionProbe {
    private(set) var count = 0
    func finish() { count += 1 }
}

private actor ClosingUSBDevice: USBRedirDevice {
    nonisolated let displayName = "Closing device"
    private let base = RecordingUSBDevice()
    private var closeWaiter: CheckedContinuation<Void, Never>?
    private var closeObservers: [CheckedContinuation<Void, Never>] = []
    func describe() async -> USBDeviceDescription { await base.describe() }
    func control(setup: USBControlSetup, data: [UInt8]) async -> USBTransferResult { .failed(.stall) }
    func bulk(endpoint: UInt8, data: [UInt8], length: Int) async -> USBTransferResult { .failed(.stall) }
    func interrupt(endpoint: UInt8, data: [UInt8], length: Int) async -> USBTransferResult { .failed(.stall) }
    func setConfiguration(_ value: UInt8) async -> USBRedirStatus { .success }
    func configuration() async -> UInt8 { 1 }
    func setAltSetting(interface: UInt8, alt: UInt8) async -> USBRedirStatus { .success }
    func altSetting(interface: UInt8) async -> UInt8? { 0 }
    func reset() async -> Bool { true }
    func abort(endpoint: UInt8) async {}
    func close() async {
        await withCheckedContinuation { continuation in
            closeWaiter = continuation
            for observer in closeObservers { observer.resume() }
            closeObservers.removeAll()
        }
    }
    func waitForClose() async {
        if closeWaiter != nil { return }
        await withCheckedContinuation { closeObservers.append($0) }
    }
    func finishClose() { closeWaiter?.resume(); closeWaiter = nil }
}

/// Deliberately finishes an old transfer after close, as a late host callback may do.
private actor DelayedBulkUSBDevice: USBRedirDevice {
    nonisolated let displayName = "Delayed bulk device"
    private let base = RecordingUSBDevice()
    private let byte: UInt8
    private var pending: CheckedContinuation<USBTransferResult, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    init(byte: UInt8) { self.byte = byte }
    func describe() async -> USBDeviceDescription { await base.describe() }
    func control(setup: USBControlSetup, data: [UInt8]) async -> USBTransferResult { .failed(.stall) }
    func bulk(endpoint: UInt8, data: [UInt8], length: Int) async -> USBTransferResult {
        await withCheckedContinuation { continuation in
            pending = continuation
            for observer in observers { observer.resume() }
            observers.removeAll()
        }
    }
    func waitForBulk() async {
        if pending != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func finishBulk() {
        pending?.resume(returning: USBTransferResult(status: .success, data: [byte]))
        pending = nil
    }
    func interrupt(endpoint: UInt8, data: [UInt8], length: Int) async -> USBTransferResult { .failed(.stall) }
    func setConfiguration(_ value: UInt8) async -> USBRedirStatus { .success }
    func configuration() async -> UInt8 { 1 }
    func setAltSetting(interface: UInt8, alt: UInt8) async -> USBRedirStatus { .success }
    func altSetting(interface: UInt8) async -> UInt8? { 0 }
    func reset() async -> Bool { true }
    func abort(endpoint: UInt8) async {}
    func close() async {}
}

@Suite("usbredir attachment lifecycle", .timeLimit(.minutes(1)))
struct USBRedirLifecycleTests {
    private func setup() async throws -> (USBRedirChannel, PausedUSBStream, GuestSide, AsyncStream<USBSlotEvent>, Task<Void, any Error>) {
        let (client, server) = await MemoryByteStream.pair()
        let stream = PausedUSBStream(client)
        let connection = ChannelConnection(type: .usbredir, id: 0, stream: stream, serverCaps: CapabilitySet(bits: []))
        let (events, sink) = AsyncStream<USBSlotEvent>.makeStream()
        let channel = USBRedirChannel(slot: 0, connection: connection, events: sink)
        let loop = Task { try await channel.run() }
        var guest = GuestSide(stream: server, caps: USBRedirCapabilities([.ids64, .bulkLength32]))
        _ = try await guest.nextPacket()
        try await guest.sendHello()
        return (channel, stream, guest, events, loop)
    }

    @Test func closeDuringAttachCannotPublishSuccess() async throws {
        let (channel, stream, guest, events, loop) = try await setup()
        defer { withExtendedLifetime(guest) {} }
        await stream.pause(send: 2) // First attachment packet, after the channel hello.
        let device = RecordingUSBDevice()
        let attach = Task { try await channel.attach(device) }
        await stream.waitForPause()
        await channel.close()
        await stream.resume()
        if case .success = await attach.result { Issue.record("Closed attachment returned success") }
        #expect(await device.closed)
        #expect(await channel.isFree == false)
        // Closing emits the legacy and ownership-aware end events, never attached.
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .detached(slot: 0, reason: .channelClosed))
        if case .attachmentEnded = await iterator.next() {} else { Issue.record("Missing attachment end identity") }
        _ = try? await loop.value
    }

    @Test func cleanupReservesSlotUntilDeviceCloseCompletes() async throws {
        let (channel, _, guest, _, loop) = try await setup()
        defer { withExtendedLifetime(guest) {} }
        let device = ClosingUSBDevice()
        try await channel.attach(device)
        let detach = Task { await channel.detach() }
        await device.waitForClose()
        #expect(await channel.isFree == false)
        await #expect(throws: USBAttachError.slotBusy) { try await channel.attach(RecordingUSBDevice()) }
        await device.finishClose()
        await detach.value
        #expect(await channel.isFree)
        await channel.close()
        _ = try? await loop.value
    }

    @Test func staleAttachmentOwnerCannotDetachReplacement() async throws {
        let (channel, _, guest, _, loop) = try await setup()
        defer { withExtendedLifetime(guest) {} }
        let oldID = UUID()
        try await channel.attach(RecordingUSBDevice(), attachmentID: oldID)
        await channel.detach(attachmentID: oldID)
        let replacement = RecordingUSBDevice()
        try await channel.attach(replacement, attachmentID: UUID())
        await channel.detach(attachmentID: oldID)
        #expect(await channel.attachedName == replacement.displayName)
        #expect(await replacement.closed == false)
        await channel.close()
        _ = try? await loop.value
    }

    @Test func closeWakesAttachWaitingForGuestHello() async throws {
        let (client, _) = await MemoryByteStream.pair()
        let connection = ChannelConnection(type: .usbredir, id: 0, stream: client, serverCaps: CapabilitySet(bits: []))
        let (_, sink) = AsyncStream<USBSlotEvent>.makeStream()
        let channel = USBRedirChannel(slot: 0, connection: connection, events: sink)
        let attach = Task { try await channel.attach(RecordingUSBDevice()) }
        // An actor round trip observes the reservation without waiting on a timeout.
        while await channel.isFree { await Task.yield() }
        await channel.close()
        await #expect(throws: USBAttachError.guestNotReady) { try await attach.value }
    }

    @Test func concurrentDetachWaitsForSameDeviceCleanup() async throws {
        let (channel, _, guest, _, loop) = try await setup()
        defer { withExtendedLifetime(guest) {} }
        let id = UUID()
        let device = ClosingUSBDevice()
        try await channel.attach(device, attachmentID: id)
        let probe = CompletionProbe()
        let first = Task { await channel.detach(attachmentID: id); await probe.finish() }
        await device.waitForClose()
        let second = Task { await channel.detach(attachmentID: id); await probe.finish() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await probe.count == 0)
        await device.finishClose()
        await first.value
        await second.value
        #expect(await probe.count == 2)
        await channel.close()
        _ = try? await loop.value
    }

    @Test func failedDisconnectDoesNotReuseAmbiguousSlot() async throws {
        let (channel, stream, guest, _, loop) = try await setup()
        defer { withExtendedLifetime(guest) {} }
        let device = RecordingUSBDevice()
        try await channel.attach(device)
        await stream.fail(send: 5)
        await channel.detach()
        #expect(await device.closed)
        #expect(await channel.isFree == false)
        await #expect(throws: USBAttachError.slotBusy) { try await channel.attach(RecordingUSBDevice()) }
        _ = try? await loop.value
    }

    @Test func detachDoesNotCancelAnInFlightTransferReply() async throws {
        let (channel, stream, firstGuest, _, loop) = try await setup()
        var guest = firstGuest
        defer { withExtendedLifetime(guest) {} }
        try await channel.attach(RecordingUSBDevice())
        for _ in 0 ..< 3 { _ = try await guest.nextPacket() }
        await stream.pause(send: 5)
        try await guest.sendBulk(id: 7, endpoint: 0x81, length: 4)
        await stream.waitForPause()
        await channel.detach()
        #expect(stream.cancelledSend.withLock { $0 } == false)
        await stream.resume()
        // The channel remains usable after retiring the old reply's task.
        try await channel.attach(RecordingUSBDevice())
        #expect(await channel.attachedName == "Recorder")
        await channel.close()
        _ = try? await loop.value
    }

    @Test func retiredTransferCannotConsumeReplacementPacketID() async throws {
        let (channel, stream, firstGuest, _, loop) = try await setup()
        var guest = firstGuest
        let old = DelayedBulkUSBDevice(byte: 0xAA)
        let replacement = DelayedBulkUSBDevice(byte: 0xBB)
        // A missing response fails promptly rather than leaving the test stream waiting.
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await stream.close()
        }
        defer { deadline.cancel() }
        do {
            try await channel.attach(old)
            for _ in 0 ..< 3 { _ = try await guest.nextPacket() }
            try await guest.sendBulk(id: 7, endpoint: 0x81, length: 1)
            await old.waitForBulk()
            await channel.detach()
            #expect(try await guest.nextPacket().type == USBRedirPacketType.deviceDisconnect.rawValue)
            try await channel.attach(replacement)
            for _ in 0 ..< 3 { _ = try await guest.nextPacket() }
            try await guest.sendBulk(id: 7, endpoint: 0x81, length: 1)
            await replacement.waitForBulk()

            await old.finishBulk()
            // Let the retired callback reach the channel while the replacement stays gated.
            try await Task.sleep(for: .milliseconds(20))
            try await guest.sendBulk(id: 7, endpoint: 0x81, length: 1)
            let duplicate = try await guest.nextPacket()
            #expect(duplicate.type == USBRedirPacketType.bulkPacket.rawValue)
            #expect(duplicate.id == 7)
            #expect(duplicate.body[1] == USBRedirStatus.inval.rawValue)
            // The old result neither sent 0xAA nor removed the replacement's reservation.
            await replacement.finishBulk()
            let completed = try await guest.nextPacket()
            #expect(completed.id == 7)
            #expect(completed.body[1] == USBRedirStatus.success.rawValue)
            #expect(completed.body.suffix(1) == [0xBB])
        } catch {
            await old.finishBulk()
            await replacement.finishBulk()
            await channel.close()
            _ = try? await loop.value
            throw error
        }
        await channel.close()
        _ = try? await loop.value
    }
}
