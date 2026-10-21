import Testing
@testable import SpiceChannels
import SpiceAgent
import SpiceTransport
import SpiceWire

/// Re-audit 2: an agent that withholds tokens while asking for capabilities over and over
/// gets one queued reply, not one per request.
@Suite("Agent outbox", .timeLimit(.minutes(1)))
struct AgentOutboxTests {
    @Test func capabilityRequestsAreCoalescedWhileTokensAreWithheld() async throws {
        let (client, serverStream) = await MemoryByteStream.pair()
        let server = ServerChannel(stream: serverStream)
        let connection = ChannelConnection(type: .main, id: 0, stream: client, serverCaps: MainChannel.capabilities)
        let (_, sink) = AsyncStream<MainEvent>.makeStream()
        let main = MainChannel(connection: connection, events: sink)
        let loop = Task { try await main.run() }

        // Agent connected with zero send tokens.
        try await server.send(MainServerMessage.agentConnectedTokens.rawValue, [0, 0, 0, 0])
        _ = try await server.expect(MainClientMessage.agentStart.rawValue)

        let request = AgentMessage.announceCapabilities(request: true, capabilities: [.clipboardByDemand])
        for _ in 0..<500 {
            for chunk in request.encodeChunks() {
                try await server.send(MainServerMessage.agentData.rawValue, chunk)
            }
        }
        // Now grant plenty of tokens and count what the client sends before a PONG.
        var tokens = ByteWriter(); tokens.writeU32(1000)
        try await server.send(MainServerMessage.agentToken.rawValue, tokens.bytes)
        var ping = ByteWriter(); ping.writeU32(1); ping.writeU64(0)
        try await server.send(BaseServerMessage.ping.rawValue, ping.bytes)
        var agentMessages = 0
        while true {
            let message = try await server.receive()
            if message.type == BaseClientMessage.pong.rawValue { break }
            if message.type == MainClientMessage.agentData.rawValue { agentMessages += 1 }
        }
        // Our own initial announcement + a single coalesced reply.
        #expect(agentMessages <= 2)
        loop.cancel()
        await main.close()
    }
}
