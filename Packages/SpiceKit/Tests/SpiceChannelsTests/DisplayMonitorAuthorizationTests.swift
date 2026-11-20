import Testing
@testable import SpiceChannels
import SpiceTransport
import SpiceWire

@Suite(.timeLimit(.minutes(1)))
struct DisplayMonitorAuthorizationTests {
    @Test func wireTopologyRetiresEarlierObservationsBeforeMetadataDeliveryAndClose() async throws {
        let (client, stream) = await MemoryByteStream.pair()
        let server = ServerChannel(stream: stream)
        let connection = ChannelConnection(type: .display, id: 0, stream: client, serverCaps: CapabilitySet())
        let (events, sink) = AsyncStream<DisplayEvent>.makeStream()
        let authority = MonitorResizeAuthority()
        let display = DisplayChannel(connection: connection, events: sink, monitorResizeAuthority: authority)
        let loop = Task { try await display.run() }
        do {
            _ = try await server.expect(DisplayClientMessage.initialize.rawValue)
            var create = ByteWriter()
            for value: UInt32 in [7, 8, 4, SurfaceFormat.xRGB32.rawValue, 1] { create.writeU32(value) }
            try await server.send(DisplayServerMessage.surfaceCreate.rawValue, create.bytes)
            var iterator = events.makeAsyncIterator()
            let first = try #require(await iterator.next())
            guard case .topologyAuthorization(let original) = first else {
                Issue.record("Authorization must precede primary geometry")
                throw TestFailure.order
            }
            #expect(original.isCurrent)
            guard case .primarySurfaceCreated(let id, _, _) = await iterator.next() else {
                throw TestFailure.order
            }
            #expect(id == 7)
            var config = ByteWriter(); config.writeU16(1); config.writeU16(4)
            for value: UInt32 in [0, 7, 8, 4, 0, 0, 0] { config.writeU32(value) }
            try await server.send(DisplayServerMessage.monitorsConfig.rawValue, config.bytes)
            var ping = ByteWriter(); ping.writeU32(1); ping.writeU64(0)
            try await server.send(BaseServerMessage.ping.rawValue, ping.bytes)
            _ = try await server.expect(BaseClientMessage.pong.rawValue)
            // No further UI events have been consumed, yet the lease is retired.
            #expect(!original.isCurrent)
            var replacement: MonitorResizeAuthorization?
            while let event = await iterator.next() {
                if case .topologyAuthorization(let value) = event { replacement = value; break }
            }
            let current = try #require(replacement)
            #expect(current.isCurrent)
            guard case .monitorsConfig(let heads) = await iterator.next() else { throw TestFailure.order }
            #expect(heads.count == 1 && heads.first?.surfaceID == 7)
            await display.close()
            #expect(!current.isCurrent)
        } catch {
            loop.cancel(); await display.close(); _ = await loop.result
            throw error
        }
        loop.cancel(); _ = await loop.result
    }
    private enum TestFailure: Error { case order }
}
