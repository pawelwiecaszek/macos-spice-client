import Foundation
import Testing
@testable import SpiceChannels
import SpiceTransport
import SpiceWire

@Suite(.timeLimit(.minutes(1)))
struct ChannelOrderingIntegrationTests {
    @Test func baseMessagesConsumeSerialsAndDeliveryNeedsExplicitCompletion() async throws {
        let (client, server) = await MemoryByteStream.pair()
        let channel = ChannelConnection(type: .display, id: 0, stream: client, serverCaps: CapabilitySet())
        var ack = ByteWriter(); ack.writeU32(9); ack.writeU32(0)
        var ping = ByteWriter(); ping.writeU32(1); ping.writeU64(0)
        let messages = [SpiceMessage(type: BaseServerMessage.setAck.rawValue, payload: ack.bytes),
                        SpiceMessage(type: BaseServerMessage.ping.rawValue, payload: ping.bytes),
                        SpiceMessage(type: BaseServerMessage.list.rawValue, payload: [0, 0]),
                        SpiceMessage(type: 101, payload: [7])]
        for message in messages { try await server.send(message.encode()) }
        #expect(try await channel.nextMessage().payload == [7])
        #expect(await channel.lastHandledSerial == 3)
        await #expect(throws: ChannelError.malformed("overlapping channel receive")) { try await channel.nextMessage() }
        await channel.messageHandled()
        #expect(await channel.lastHandledSerial == 4)
        await channel.close()
    }

    @Test func receivedPeerMessageDoesNotReleaseBarrierUntilHandlerFinishes() async throws {
        let sync = ChannelSynchronization()
        let (a, serverA) = await MemoryByteStream.pair()
        let (b, serverB) = await MemoryByteStream.pair()
        let owner = ChannelConnection(type: .display, id: 0, stream: a, serverCaps: CapabilitySet(), synchronization: sync)
        let peer = ChannelConnection(type: .cursor, id: 0, stream: b, serverCaps: CapabilitySet(), synchronization: sync)
        try await owner.prepare(); try await peer.prepare()
        try await sync.expect([.init(type: .display, id: 0), .init(type: .cursor, id: 0)])
        try await serverB.send(SpiceMessage(type: 101, payload: []).encode())
        _ = try await peer.nextMessage() // Received, but its handler is deliberately unfinished.
        try await serverA.send(SpiceMessage(type: BaseServerMessage.waitForChannels.rawValue,
            payload: Self.waitPayload(type: .cursor, id: 0, serial: 1)).encode())
        try await serverA.send(SpiceMessage(type: 101, payload: [42]).encode())
        let read = Task { try await owner.nextMessage() }
        await Self.awaitWaiter(sync)
        #expect(await owner.lastHandledSerial == 0)
        await peer.messageHandled()
        #expect(try await read.value.payload == [42])
        #expect(await owner.lastHandledSerial == 1, "the completed base barrier counts as one message")
        await owner.messageHandled()
        #expect(await owner.lastHandledSerial == 2)
        await owner.close(); await peer.close()
    }

    @Test func malformedBarrierClosesItsOrderingIdentity() async throws {
        let sync = ChannelSynchronization()
        let (a, server) = await MemoryByteStream.pair()
        let owner = ChannelConnection(type: .display, id: 0, stream: a, serverCaps: CapabilitySet(), synchronization: sync)
        try await owner.prepare()
        let token = UUID(), peer = ChannelSynchronization.Key(type: .cursor, id: 0)
        try await sync.register(peer, token: token)
        try await server.send(SpiceMessage(type: BaseServerMessage.waitForChannels.rawValue, payload: [1]).encode())
        await #expect(throws: (any Error).self) { try await owner.nextMessage() }
        let wait = try WaitForChannels(decoding: Self.waitPayload(type: .display, id: 0, serial: 1))
        await #expect(throws: ChannelSynchronization.Failure.channelClosed) {
            try await sync.wait(wait.entries, owner: peer, token: token, currentSerial: 1)
        }
        await sync.shutdown()
    }

    static func waitPayload(type: ChannelType, id: UInt8, serial: UInt64) -> [UInt8] {
        var w = ByteWriter(); w.writeU8(1); w.writeU8(type.rawValue); w.writeU8(id); w.writeU64(serial)
        return w.bytes
    }

    static func awaitWaiter(_ sync: ChannelSynchronization) async {
        for _ in 0..<10_000 {
            if await sync.pendingWaitCount == 1 { return }
            await Task.yield()
        }
        Issue.record("Expected channel barrier was not reached")
    }
}
