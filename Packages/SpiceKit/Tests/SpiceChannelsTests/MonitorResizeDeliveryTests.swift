import Testing
@testable import SpiceChannels
import SpiceAgent
import SpiceTransport
import SpiceWire

@Suite("Monitor resize delivery", .timeLimit(.minutes(1)))
struct MonitorResizeDeliveryTests {
    private let capabilities: [AgentCapability] = [.monitorsConfig, .sparseMonitorsConfig, .monitorsConfigPosition]

    @Test func tokenStarvationCoalescesCompleteLayoutsAndPreservesSparseSlots() async throws {
        try await withMain(capabilities: capabilities) { main, server in
            let original = try #require(GuestMonitorLayout([
                .init(id: 0, width: 100, height: 100, x: 0, y: 0),
                .init(id: 2, width: 100, height: 100, x: 100, y: 0)
            ]))
            var last = original
            for width in 100..<300 {
                last = try #require(original.resizing(id: 0, width: UInt32(width), height: 100))
                #expect(try await main.requestMonitorLayout(last))
            }
            try await grantTokens(server)
            let sent = try await barrier(server).filter { $0.knownType == .monitorsConfig }
            #expect(sent.count == 1)
            let caps = CapabilitySet(bits: capabilities.map(\.rawValue))
            #expect(sent.first?.data == last.message(capabilities: caps)?.data)
        }
    }

    @Test func disconnectAndCapabilityDowngradeRetirePendingLayouts() async throws {
        try await withMain(capabilities: capabilities) { main, server in
            let sparse = try #require(GuestMonitorLayout([.init(id: 2, width: 100, height: 100, x: 0, y: 0)]))
            #expect(try await main.requestMonitorLayout(sparse))
            try await announce(server, [.monitorsConfig])
            _ = try await barrier(server)
            #expect(try await !main.requestMonitorLayout(sparse))
            try await grantTokens(server)
            #expect(try await barrier(server).allSatisfy { $0.knownType != .monitorsConfig })

            try await server.send(MainServerMessage.agentDisconnected.rawValue, [])
            _ = try await barrier(server)
            #expect(try await !main.requestMonitorLayout(sparse))
            try await server.send(MainServerMessage.agentConnectedTokens.rawValue, [0, 0, 0, 0])
            _ = try await server.expect(MainClientMessage.agentStart.rawValue)
            try await announce(server, capabilities)
            _ = try await barrier(server)
            try await grantTokens(server)
            #expect(try await barrier(server).allSatisfy { $0.knownType != .monitorsConfig })
        }
    }

    @Test func topologyOrUserIntentInvalidationDropsTokenStarvedRequests() async throws {
        try await withMain(capabilities: capabilities) { main, server in
            let layout = try #require(GuestMonitorLayout([.init(id: 0, width: 100, height: 100, x: 0, y: 0)]))
            let topology = MonitorResizeAuthority(), intent = MonitorResizeAuthority()
            let topologyObservation = topology.advance(), oldIntent = intent.advance()
            #expect(try await main.requestMonitorLayout(layout, authorizations: [topologyObservation, oldIntent]))
            topology.invalidate() // Wire metadata can change before the UI consumes it.
            try await grantTokens(server)
            #expect(try await barrier(server).allSatisfy { $0.knownType != .monitorsConfig })
            #expect(try await !main.requestMonitorLayout(layout, authorizations: [topologyObservation, oldIntent]))

            // Reconnect resets send tokens, allowing the independent UI-close
            // invalidation to be exercised before any message begins.
            try await server.send(MainServerMessage.agentDisconnected.rawValue, [])
            _ = try await barrier(server)
            try await server.send(MainServerMessage.agentConnectedTokens.rawValue, [0, 0, 0, 0])
            _ = try await server.expect(MainClientMessage.agentStart.rawValue)
            try await announce(server, capabilities)
            _ = try await barrier(server)
            #expect(try await main.requestMonitorLayout(layout, authorizations: [topology.advance(), oldIntent]))
            intent.invalidate()
            try await grantTokens(server)
            #expect(try await barrier(server).allSatisfy { $0.knownType != .monitorsConfig })
        }
    }

    @Test func channelSetChangesRetireQueuedRequestsBeforeUIConsumption() async throws {
        try await withMain(capabilities: capabilities) { main, server, lifecycle in
            let layout = try #require(GuestMonitorLayout([.init(id: 0, width: 100, height: 100, x: 0, y: 0)]))
            #expect(try await main.requestMonitorLayout(layout, authorizations: [lifecycle]))
            var channels = ByteWriter(); channels.writeU32(2)
            channels.writeU8(ChannelType.display.rawValue); channels.writeU8(0)
            channels.writeU8(ChannelType.display.rawValue); channels.writeU8(1)
            try await server.send(MainServerMessage.channelsList.rawValue, channels.bytes)
            _ = try await barrier(server)
            #expect(!lifecycle.isCurrent)
            try await grantTokens(server)
            #expect(try await barrier(server).allSatisfy { $0.knownType != .monitorsConfig })
        }
    }

    @Test func preDisconnectProducerCannotEnterAReplacementAgent() async throws {
        try await withMain(capabilities: capabilities) { main, server, lifecycle in
            let layout = try #require(GuestMonitorLayout([.init(id: 0, width: 100, height: 100, x: 0, y: 0)]))
            try await server.send(MainServerMessage.agentDisconnected.rawValue, [])
            _ = try await barrier(server)
            try await server.send(MainServerMessage.agentConnectedTokens.rawValue, [0, 0, 0, 0])
            _ = try await server.expect(MainClientMessage.agentStart.rawValue)
            try await announce(server, capabilities)
            _ = try await barrier(server)
            #expect(try await !main.requestMonitorLayout(layout, authorizations: [lifecycle]))
            try await grantTokens(server)
            #expect(try await barrier(server).allSatisfy { $0.knownType != .monitorsConfig })
        }
    }

    private func withMain(capabilities: [AgentCapability],
                          operation: (MainChannel, ServerChannel) async throws -> Void) async throws {
        try await withMain(capabilities: capabilities) { main, server, _ in try await operation(main, server) }
    }

    private func withMain(capabilities: [AgentCapability],
                          operation: (MainChannel, ServerChannel, MonitorResizeAuthorization) async throws -> Void) async throws {
        let (client, stream) = await MemoryByteStream.pair()
        let server = ServerChannel(stream: stream)
        let connection = ChannelConnection(type: .main, id: 0, stream: client, serverCaps: MainChannel.capabilities)
        let (events, sink) = AsyncStream<MainEvent>.makeStream()
        let main = MainChannel(connection: connection, events: sink)
        let loop = Task { try await main.run() }
        do {
            try await server.send(MainServerMessage.agentConnectedTokens.rawValue, [0, 0, 0, 0])
            _ = try await server.expect(MainClientMessage.agentStart.rawValue)
            try await announce(server, capabilities)
            _ = try await barrier(server)
            var lifecycle: MonitorResizeAuthorization?
            for await event in events {
                if case .monitorResizeAuthorization(let value) = event { lifecycle = value }
                if case .agentCapabilities = event { break }
            }
            try await operation(main, server, #require(lifecycle))
        } catch {
            loop.cancel(); await main.close(); _ = await loop.result
            throw error
        }
        loop.cancel(); await main.close(); _ = await loop.result
    }

    private func announce(_ server: ServerChannel, _ caps: [AgentCapability]) async throws {
        for chunk in AgentMessage.announceCapabilities(request: false, capabilities: caps).encodeChunks() {
            try await server.send(MainServerMessage.agentData.rawValue, chunk)
        }
    }

    private func grantTokens(_ server: ServerChannel) async throws {
        var writer = ByteWriter(); writer.writeU32(1000)
        try await server.send(MainServerMessage.agentToken.rawValue, writer.bytes)
    }

    private func barrier(_ server: ServerChannel) async throws -> [AgentMessage] {
        var ping = ByteWriter(); ping.writeU32(1); ping.writeU64(0)
        try await server.send(BaseServerMessage.ping.rawValue, ping.bytes)
        var assembler = AgentMessageAssembler(), messages: [AgentMessage] = []
        while true {
            let message = try await server.receive()
            if message.type == BaseClientMessage.pong.rawValue { return messages }
            if message.type == MainClientMessage.agentData.rawValue { messages += try assembler.feed(message.payload) }
        }
    }
}
