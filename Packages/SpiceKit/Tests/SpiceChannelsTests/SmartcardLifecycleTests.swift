import Foundation
import Synchronization
import Testing
@testable import SpiceChannels
import SpiceTransport
import SpiceWire

private actor GatedSmartcard: SmartcardCard {
    nonisolated let displayName = "Simulated card"
    let atr: [UInt8]
    var holdConnect: Bool
    var holdDisconnect: Bool
    var holdTransmit: Bool
    private var connectWaiter: CheckedContinuation<Void, Never>?
    private var disconnectWaiter: CheckedContinuation<Void, Never>?
    private var transmitWaiter: CheckedContinuation<Void, Never>?
    private(set) var connectStarted = false
    private(set) var disconnectStarted = false
    private(set) var transmitStarted = false
    private(set) var connected = false
    private(set) var disconnects = 0

    init(atr: [UInt8] = [0x3B, 1], holdConnect: Bool = false,
         holdDisconnect: Bool = false, holdTransmit: Bool = false) {
        self.atr = atr
        self.holdConnect = holdConnect
        self.holdDisconnect = holdDisconnect
        self.holdTransmit = holdTransmit
    }
    func connect() async throws -> [UInt8] {
        connectStarted = true
        if holdConnect { await withCheckedContinuation { connectWaiter = $0 } }
        connected = true
        return atr
    }
    func disconnect() async {
        disconnects += 1
        disconnectStarted = true
        if holdDisconnect { await withCheckedContinuation { disconnectWaiter = $0 } }
        connected = false
    }
    func transmit(_ apdu: [UInt8]) async throws -> [UInt8] {
        transmitStarted = true
        if holdTransmit { await withCheckedContinuation { transmitWaiter = $0 } }
        return [0xAA, 0x90, 0]
    }
    func finishConnect() { holdConnect = false; connectWaiter?.resume(); connectWaiter = nil }
    func finishDisconnect() { holdDisconnect = false; disconnectWaiter?.resume(); disconnectWaiter = nil }
    func finishTransmit() { holdTransmit = false; transmitWaiter?.resume(); transmitWaiter = nil }
}

private actor GatedSmartcardStream: SpiceByteStream {
    let base: MemoryByteStream
    private var sends = 0
    private var pauseAt: Int?
    private var failAt: Int?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var paused = false
    init(_ base: MemoryByteStream) { self.base = base }
    func pause(send: Int) { pauseAt = send }
    func fail(send: Int) { failAt = send }
    func resume() { waiter?.resume(); waiter = nil }
    func send(_ bytes: [UInt8]) async throws {
        sends += 1
        if sends == failAt { throw TransportError.closed }
        try await base.send(bytes)
        if sends == pauseAt { await withCheckedContinuation { waiter = $0; paused = true } }
        try Task.checkCancellation()
    }
    func receive(exactly count: Int) async throws -> [UInt8] { try await base.receive(exactly: count) }
    func close() async { await base.close() }
}

@Suite("Smartcard attachment lifecycle", .timeLimit(.minutes(1)))
struct SmartcardLifecycleTests {
    private struct Fixture {
        let channel: SmartcardChannel
        let stream: GatedSmartcardStream
        let server: SmartcardServer
        let events: AsyncStream<SmartcardEvent>
        let sink: AsyncStream<SmartcardEvent>.Continuation
        let loop: Task<Void, any Error>
    }
    private func setup() async -> Fixture {
        let (client, server) = await MemoryByteStream.pair()
        let stream = GatedSmartcardStream(client)
        let connection = ChannelConnection(type: .smartcard, id: 0, stream: stream, serverCaps: CapabilitySet(bits: []))
        let (events, sink) = AsyncStream<SmartcardEvent>.makeStream()
        let channel = SmartcardChannel(connection: connection, events: sink)
        return Fixture(channel: channel, stream: stream, server: SmartcardServer(stream: server),
                       events: events, sink: sink, loop: Task { try await channel.run() })
    }
    private func acknowledge(_ fixture: Fixture) async throws {
        #expect(try await fixture.server.read().type == .readerAdd)
        try await fixture.server.write(.error(.success, readerID: 1))
    }
    private func wait(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw Timeout.elapsed
    }
    private enum Timeout: Error { case elapsed }

    @Test func closeWakesReaderWaitWithoutOpeningTheCard() async throws {
        let fixture = await setup()
        let card = GatedSmartcard()
        let insertion = Task { try await fixture.channel.insert(card) }
        #expect(try await fixture.server.read().type == .readerAdd)
        await fixture.channel.close()
        await #expect(throws: SmartcardError.readerNotAccepted) { try await insertion.value }
        #expect(await card.connectStarted == false)
        _ = try? await fixture.loop.value
    }

    @Test func closeDuringConnectIsPromptAndLateSessionIsReleased() async throws {
        let fixture = await setup()
        let card = GatedSmartcard(holdConnect: true)
        let insertion = Task { try await fixture.channel.insert(card) }
        try await acknowledge(fixture)
        try await wait { await card.connectStarted }
        // Close must return even while a hardware callback is still pending.
        await fixture.channel.close()
        #expect(await card.disconnects == 0)
        await card.finishConnect()
        await #expect(throws: SmartcardError.readerNotAccepted) { try await insertion.value }
        #expect(await card.connected == false)
        #expect(await card.disconnects == 1)
        _ = try? await fixture.loop.value
    }

    @Test func closeDuringATRSendCannotPublishInserted() async throws {
        let fixture = await setup()
        await fixture.stream.pause(send: 2)
        let card = GatedSmartcard()
        let insertion = Task { try await fixture.channel.insert(card) }
        try await acknowledge(fixture)
        try await wait { await fixture.stream.paused }
        await fixture.channel.close()
        await fixture.stream.resume()
        await #expect(throws: SmartcardError.readerNotAccepted) { try await insertion.value }
        fixture.sink.finish()
        var events: [SmartcardEvent] = []
        for await event in fixture.events { events.append(event) }
        #expect(!events.contains(.inserted(name: card.displayName)))
        #expect(await card.connected == false)
        _ = try? await fixture.loop.value
    }

    @Test func cleanupReservesCardAndStaleOwnerCannotRemoveReplacement() async throws {
        let fixture = await setup()
        let oldID = UUID()
        let old = GatedSmartcard(holdDisconnect: true)
        let insertion = Task { try await fixture.channel.insert(old, attachmentID: oldID) }
        try await acknowledge(fixture)
        #expect(try await fixture.server.read().type == .atr)
        try await insertion.value
        let remove = Task { await fixture.channel.remove(attachmentID: oldID) }
        #expect(try await fixture.server.read().type == .cardRemove)
        try await wait { await old.disconnectStarted }
        await #expect(throws: SmartcardError.cardAlreadyShared) { try await fixture.channel.insert(GatedSmartcard()) }
        let joined = Mutex(false)
        let duplicate = Task { await fixture.channel.remove(attachmentID: oldID); joined.withLock { $0 = true } }
        try await Task.sleep(for: .milliseconds(20))
        #expect(joined.withLock { !$0 })
        await old.finishDisconnect()
        await remove.value
        await duplicate.value
        let replacement = GatedSmartcard()
        try await fixture.channel.insert(replacement)
        #expect(try await fixture.server.read().type == .atr)
        await fixture.channel.remove(attachmentID: oldID)
        #expect(await replacement.connected)
        await fixture.channel.close()
        _ = try? await fixture.loop.value
    }

    @Test func emptyATRReturnsExclusiveSession() async throws {
        let fixture = await setup()
        let card = GatedSmartcard(atr: [])
        let insertion = Task { try await fixture.channel.insert(card) }
        try await acknowledge(fixture)
        await #expect(throws: SmartcardError.noATR) { try await insertion.value }
        #expect(await card.connected == false)
        #expect(await card.disconnects == 1)
        await fixture.channel.close()
        _ = try? await fixture.loop.value
    }

    @Test func failedATRSendClosesAmbiguousChannelAndReleasesCard() async throws {
        let fixture = await setup()
        await fixture.stream.fail(send: 2)
        let card = GatedSmartcard()
        let insertion = Task { try await fixture.channel.insert(card) }
        try await acknowledge(fixture)
        await #expect(throws: TransportError.closed) { try await insertion.value }
        #expect(await card.connected == false)
        await #expect(throws: SmartcardError.readerNotAccepted) { try await fixture.channel.insert(GatedSmartcard()) }
        await fixture.channel.close()
        _ = try? await fixture.loop.value
    }

    @Test func retiredAPDUCannotReplyForReplacementCard() async throws {
        let fixture = await setup()
        let oldID = UUID()
        let old = GatedSmartcard(holdTransmit: true)
        let insertion = Task { try await fixture.channel.insert(old, attachmentID: oldID) }
        try await acknowledge(fixture)
        #expect(try await fixture.server.read().type == .atr)
        try await insertion.value
        try await fixture.server.write(VSCMessage(.apdu, readerID: 1, data: [0]))
        try await wait { await old.transmitStarted }
        await fixture.channel.remove(attachmentID: oldID)
        #expect(try await fixture.server.read().type == .cardRemove)
        try await fixture.channel.insert(GatedSmartcard())
        #expect(try await fixture.server.read().type == .atr)
        await old.finishTransmit()
        try await fixture.server.write(VSCMessage(.flush, readerID: 1))
        #expect(try await fixture.server.read().type == .flushComplete)
        await fixture.channel.close()
        _ = try? await fixture.loop.value
    }
}
