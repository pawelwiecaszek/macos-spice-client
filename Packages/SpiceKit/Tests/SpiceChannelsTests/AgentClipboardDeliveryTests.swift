import Testing
import Synchronization
@testable import SpiceChannels
import SpiceAgent
import SpiceTransport
import SpiceWire

@Suite("Agent clipboard delivery", .timeLimit(.minutes(1)))
struct AgentClipboardDeliveryTests {
    private let capabilities: [AgentCapability] = [.clipboardByDemand, .clipboardSelection, .guestLineEndCRLF]

    @Test func revokedSharingDropsQueuedDataAndFreshActionsUseNegotiatedEncoding() async throws {
        try await withMain { fixture in
            let authorization = try #require(await fixture.main.clipboardAuthorization)
            let sharing = ClipboardSharingAuthority()
            let revoked = sharing.current
            #expect(await fixture.main.enqueueClipboard(.provide(.utf8Text, Array("old".utf8)),
                authorization: authorization, sharing: revoked))
            sharing.invalidate()
            #expect(await !fixture.main.enqueueClipboard(.request(.png), authorization: authorization, sharing: revoked))

            for action: AgentClipboardAction in [.offer([.utf8Text, .png]), .request(.png),
                .provide(.utf8Text, Array("a\nb".utf8)), .release] {
                #expect(await fixture.main.enqueueClipboard(action, authorization: authorization, sharing: sharing.current))
            }
            try await grantTokens(fixture.server)
            let sent = try await barrier(fixture.server)
            let decoded = try sent.compactMap { try ClipboardCodec.decode($0, selectionHeader: true) }
            #expect(decoded == [.grab(selection: .clipboard, types: [.utf8Text, .png]),
                                .request(selection: .clipboard, type: .png),
                                .data(selection: .clipboard, type: .utf8Text, bytes: Array("a\r\nb".utf8)),
                                .release(selection: .clipboard)])
        }
    }

    @Test func capabilityChangesRetireQueuedActionsAndAlreadyDeliveredObservations() async throws {
        try await withMain { fixture in
            let authorization = try #require(await fixture.main.clipboardAuthorization)
            #expect(await fixture.main.enqueueClipboard(.provide(.utf8Text, Array("stale".utf8)),
                authorization: authorization, sharing: ClipboardSharingAuthority().current))
            try await sendAgent(ClipboardCodec.grab([.png], selectionHeader: true), to: fixture.server)
            _ = try await barrier(fixture.server)
            var iterator = fixture.stream.makeAsyncIterator()
            let delivered = try #require(await iterator.next())
            #expect(delivered.authorization.isCurrent)

            // Remove selection/CRLF negotiation without replacing the agent.
            try await announce([.clipboardByDemand], to: fixture.server)
            _ = try await barrier(fixture.server)
            #expect(!delivered.authorization.isCurrent)
            #expect(delivered.authorization.agent.isCurrent)
            #expect(await !fixture.main.enqueueClipboard(.release, authorization: authorization,
                                                         sharing: ClipboardSharingAuthority().current))
            try await grantTokens(fixture.server)
            #expect(try await barrier(fixture.server).allSatisfy { $0.knownType != .clipboard })

            // Availability can disappear while UI callbacks are still queued.
            let current = try #require(await fixture.main.clipboardAuthorization)
            try await announce([], to: fixture.server)
            _ = try await barrier(fixture.server)
            #expect(!current.isCurrent)
            #expect(await fixture.main.clipboardAuthorization == nil)
            #expect(await fixture.main.isAgentConnected)
        }
    }

    @Test func replacementAgentRejectsOldProducersAndInvalidatesUnreadDeliveries() async throws {
        try await withMain { fixture in
            let old = try #require(await fixture.main.clipboardAuthorization)
            #expect(await fixture.main.enqueueClipboard(.provide(.png, [1, 2, 3]), authorization: old,
                                                         sharing: ClipboardSharingAuthority().current))
            try await sendAgent(ClipboardCodec.grab([.utf8Text], selectionHeader: true), to: fixture.server)
            _ = try await barrier(fixture.server)
            try await fixture.server.send(MainServerMessage.agentDisconnected.rawValue, [])
            _ = try await barrier(fixture.server)
            try await fixture.server.send(MainServerMessage.agentConnectedTokens.rawValue, [0, 0, 0, 0])
            _ = try await fixture.server.expect(MainClientMessage.agentStart.rawValue)
            try await announce(capabilities, to: fixture.server)
            _ = try await barrier(fixture.server)
            #expect(!old.agent.isCurrent)
            #expect(await !fixture.main.enqueueClipboard(.release, authorization: old,
                                                         sharing: ClipboardSharingAuthority().current))
            var iterator = fixture.stream.makeAsyncIterator()
            let unread = try #require(await iterator.next())
            #expect(!unread.authorization.isCurrent)
            #expect(await fixture.main.clipboardAuthorization != nil)
            try await grantTokens(fixture.server)
            #expect(try await barrier(fixture.server).allSatisfy { $0.knownType != .clipboard })
        }
    }

    @Test func incomingControlsAndDataKeepWireOrder() async throws {
        try await withMain { fixture in
            let messages = [ClipboardCodec.grab([.png], selectionHeader: true),
                            ClipboardCodec.release(selectionHeader: true),
                            ClipboardCodec.data(.png, bytes: [1, 2, 3], selectionHeader: true)]
            for message in messages { try await sendAgent(message, to: fixture.server) }
            _ = try await barrier(fixture.server)
            var iterator = fixture.stream.makeAsyncIterator()
            let first = try #require(await iterator.next())
            let second = try #require(await iterator.next())
            let third = try #require(await iterator.next())
            #expect(first.message == .grab(selection: .clipboard, types: [.png]))
            #expect(second.message == .release(selection: .clipboard))
            #expect(third.message == .data(selection: .clipboard, type: .png, bytes: [1, 2, 3]))
            #expect(!first.authorization.isCurrent, "The later RELEASE retires the earlier GRAB ownership")
            #expect(first.authorization.agent.isCurrent)
            #expect(second.authorization.isCurrent && third.authorization.isCurrent)
        }
    }

    @Test func releaseOrNewGrabRetiresHeldDataBeforeUIConsumesOwnershipChange() async throws {
        for change in [ClipboardCodec.release(selectionHeader: true), ClipboardCodec.grab([.png], selectionHeader: true)] {
            try await withMain { fixture in
                try await sendAgent(ClipboardCodec.grab([.utf8Text], selectionHeader: true), to: fixture.server)
                _ = try await barrier(fixture.server)
                var iterator = fixture.stream.makeAsyncIterator()
                let offer = try #require(await iterator.next())
                let sharing = ClipboardSharingAuthority()
                #expect(await fixture.main.enqueueClipboard(.request(.utf8Text), authorization: offer.authorization,
                                                             sharing: sharing.requestAuthorization()))
                try await grantTokens(fixture.server)
                let requested = try await barrier(fixture.server)
                #expect(requested.contains { $0.knownType == .clipboardRequest })

                try await sendAgent(ClipboardCodec.data(.utf8Text, bytes: Array("old\r\n".utf8), selectionHeader: true),
                                    to: fixture.server)
                _ = try await barrier(fixture.server)
                let held = try #require(await iterator.next())
                #expect(held.message == .data(selection: .clipboard, type: .utf8Text, bytes: Array("old\n".utf8)))
                #expect(held.authorization.isCurrent)

                try await sendAgent(change, to: fixture.server)
                _ = try await barrier(fixture.server)
                // The UI still holds DATA and has not consumed the next control.
                #expect(!held.authorization.isCurrent)
                #expect(held.authorization.agent.isCurrent, "Ownership loss is not an agent-drain boundary")
                let ownership = try #require(await iterator.next())
                let decodedChange = try ClipboardCodec.decode(change, selectionHeader: true)
                let expected = try #require(decodedChange)
                #expect(ownership.message == expected)
                #expect(ownership.authorization.isCurrent)
                #expect(await fixture.main.clipboardAuthorization == ownership.authorization)
            }
        }
    }

    @Test func inboundEventPressureEndsOnlyClipboardAndRetiresQueuedObservations() async throws {
        try await withMain(maximumEvents: 2, maximumBytes: 8) { fixture in
            let old = try #require(await fixture.main.clipboardAuthorization)
            for message in [ClipboardCodec.grab([.png], selectionHeader: true),
                            ClipboardCodec.request(.png, selectionHeader: true),
                            ClipboardCodec.release(selectionHeader: true)] {
                try await sendAgent(message, to: fixture.server)
            }
            _ = try await barrier(fixture.server)
            #expect(!old.isCurrent)
            #expect(await fixture.main.clipboardAuthorization == nil)
            #expect(await fixture.main.isAgentConnected)
            var iterator = fixture.stream.makeAsyncIterator()
            #expect(await iterator.next() == nil)
        }
    }

    @Test func inboundBytePressureCannotRetainMultipleLargeReplies() async throws {
        try await withMain(maximumEvents: 16, maximumBytes: 8) { fixture in
            let old = try #require(await fixture.main.clipboardAuthorization)
            for _ in 0..<2 { try await sendAgent(ClipboardCodec.data(.png, bytes: [1, 2, 3, 4, 5], selectionHeader: true), to: fixture.server) }
            _ = try await barrier(fixture.server)
            #expect(!old.isCurrent)
            #expect(await fixture.main.isAgentConnected)
            var iterator = fixture.stream.makeAsyncIterator()
            #expect(await iterator.next() == nil)
        }
    }

    @Test func malformedControlDisablesClipboardWithoutClosingMain() async throws {
        try await withMain { fixture in
            let old = try #require(await fixture.main.clipboardAuthorization)
            var malformed = ByteWriter(); malformed.writeU32(0)
            for _ in 0..<65 { malformed.writeU32(.max) }
            try await sendAgent(AgentMessage(type: .clipboardGrab, data: malformed.bytes), to: fixture.server)
            _ = try await barrier(fixture.server)
            #expect(!old.isCurrent)
            #expect(await fixture.main.clipboardAuthorization == nil)
            #expect(await fixture.main.isAgentConnected)
            var iterator = fixture.stream.makeAsyncIterator()
            #expect(await iterator.next() == nil)
        }
    }

    @Test func outboundControlPressureEndsClipboardWithoutSendingPartialState() async throws {
        try await withMain { fixture in
            let authorization = try #require(await fixture.main.clipboardAuthorization)
            let sharing = ClipboardSharingAuthority()
            for _ in 0..<16 {
                #expect(await fixture.main.enqueueClipboard(.offer([.png]), authorization: authorization, sharing: sharing.current))
            }
            #expect(await !fixture.main.enqueueClipboard(.request(.png), authorization: authorization, sharing: sharing.current))
            #expect(!authorization.isCurrent)
            #expect(await fixture.main.pendingAgentBytes <= MainChannel.maxAgentOutboxBytes)
            try await grantTokens(fixture.server)
            let sent = try await barrier(fixture.server)
            #expect(sent.allSatisfy { $0.knownType != .clipboardGrab && $0.knownType != .clipboardRequest })
            #expect(await fixture.main.isAgentConnected)
            var iterator = fixture.stream.makeAsyncIterator()
            #expect(await iterator.next() == nil)
        }
    }

    @Test func cancelledConsumerMakesSubsequentPeerDeliveryFailClosed() async throws {
        try await withMain { fixture in
            let stream = fixture.stream
            let consumer = Task { var iterator = stream.makeAsyncIterator(); return await iterator.next() }
            for _ in 0..<10_000 {
                if fixture.buffer.hasWaitingConsumer { break }
                await Task.yield()
            }
            #expect(fixture.buffer.hasWaitingConsumer)
            consumer.cancel()
            #expect(await consumer.value == nil)
            try await sendAgent(ClipboardCodec.grab([.png], selectionHeader: true), to: fixture.server)
            _ = try await barrier(fixture.server)
            #expect(await fixture.main.clipboardAuthorization == nil)
            #expect(await fixture.main.isAgentConnected)
        }
    }

    @Test func cancelledMonitorCallerDoesNotOwnSharedSocketWrites() async throws {
        try await withMain { fixture in
            try await announce(capabilities + [.monitorsConfig], to: fixture.server)
            try await grantTokens(fixture.server)
            _ = try await barrier(fixture.server)
            let layout = try #require(GuestMonitorLayout([.init(id: 0, width: 800, height: 600, x: 0, y: 0)]))
            let main = fixture.main
            let caller = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await main.requestMonitorLayout(layout)
            }
            #expect(try await caller.value)
            _ = try await barrier(fixture.server)
            #expect(fixture.writeProbe.cancelledWrites == 0)
            #expect(await fixture.main.isAgentConnected)
        }
    }

    @Test func cancelledGenericAgentCallerDoesNotOwnSharedSocketWrites() async throws {
        try await withMain { fixture in
            try await grantTokens(fixture.server)
            _ = try await barrier(fixture.server)
            let main = fixture.main
            let caller = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await main.sendToAgent(.announceCapabilities(request: false, capabilities: [.clipboardByDemand]))
            }
            try await caller.value
            _ = try await barrier(fixture.server)
            #expect(fixture.writeProbe.cancelledWrites == 0)
            #expect(await fixture.main.isAgentConnected)
        }
    }

    @Test func firstChunkCommitRechecksRevocationAfterEncoding() {
        let agent = AgentAuthorizationSource(), negotiation = AgentAuthorizationSource()
        let authorization = ClipboardAgentAuthorization(agent: agent.current, negotiation: negotiation.current)
        let sharing = ClipboardSharingAuthority()
        let admission = ClipboardCommitAuthorization(agent: authorization, sharing: sharing.current)
        #expect(admission.canBegin(current: authorization))
        // Encoding can finish after admission but before a socket chunk begins.
        let encoded = ClipboardCodec.data(.utf8Text, bytes: Array("stale".utf8), selectionHeader: true).encodeChunks()
        #expect(!encoded.isEmpty)
        sharing.invalidate()
        #expect(!admission.canBegin(current: authorization))
        #expect(!admission.begin(current: authorization))

        let fresh = ClipboardCommitAuthorization(agent: authorization, sharing: sharing.current)
        negotiation.advance()
        #expect(!fresh.begin(current: authorization))
        let current = ClipboardAgentAuthorization(agent: agent.current, negotiation: negotiation.current)
        let cancelled = sharing.requestAuthorization()
        #expect(cancelled.requestReceipt?.cancelIfUnsent() == true)
        #expect(!ClipboardCommitAuthorization(agent: current, sharing: cancelled).begin(current: current))
    }

    @Test func committedRequestReceiptCannotBeReusedOrChangedIntoUnsentProof() throws {
        let agent = AgentAuthorizationSource(), negotiation = AgentAuthorizationSource()
        let authorization = ClipboardAgentAuthorization(agent: agent.current, negotiation: negotiation.current)
        let sharing = ClipboardSharingAuthority().requestAuthorization()
        let receipt = try #require(sharing.requestReceipt)
        let admission = ClipboardCommitAuthorization(agent: authorization, sharing: sharing)
        #expect(admission.begin(current: authorization))
        #expect(receipt.status == .committed)
        #expect(!admission.canBegin(current: authorization))
        #expect(!admission.begin(current: authorization), "A duplicate message cannot reuse the receipt")
        admission.discardUnstarted()
        #expect(receipt.status == .committed)
        #expect(!receipt.cancelIfUnsent())
        receipt.discardBeforeSend()
        #expect(receipt.status == .committed, "Committed requests must retain their response-drain barrier")
    }

    private struct Fixture {
        let main: MainChannel
        let server: ServerChannel
        let stream: AsyncStream<AgentClipboardDelivery>
        let buffer: ClipboardDeliveryBuffer
        let writeProbe: WriteProbe
    }

    private func withMain(maximumEvents: Int = 16, maximumBytes: Int = ClipboardCodec.maxDataSize,
                          operation: (Fixture) async throws -> Void) async throws {
        let (client, serverStream) = await MemoryByteStream.pair()
        let writeProbe = WriteProbe()
        let server = ServerChannel(stream: serverStream)
        let connection = ChannelConnection(type: .main, id: 0,
            stream: CancellationAwareStream(base: client, probe: writeProbe), serverCaps: MainChannel.capabilities)
        let (_, sink) = AsyncStream<MainEvent>.makeStream()
        let (stream, buffer) = ClipboardDeliveryBuffer.makeStream(maximumEvents: maximumEvents, maximumBytes: maximumBytes)
        let main = MainChannel(connection: connection, events: sink, clipboardBuffer: buffer)
        let loop = Task { try await main.run() }
        do {
            try await server.send(MainServerMessage.agentConnectedTokens.rawValue, [0, 0, 0, 0])
            _ = try await server.expect(MainClientMessage.agentStart.rawValue)
            try await announce(capabilities, to: server)
            _ = try await barrier(server)
            try await operation(Fixture(main: main, server: server, stream: stream, buffer: buffer, writeProbe: writeProbe))
        } catch {
            loop.cancel(); await main.close(); _ = await loop.result
            throw error
        }
        loop.cancel(); await main.close(); _ = await loop.result
    }

    private final class WriteProbe: Sendable {
        private let count = Mutex(0)
        var cancelledWrites: Int { count.withLock { $0 } }
        func recordCancelledWrite() { count.withLock { $0 += 1 } }
    }

    /// Models NetworkByteStream: a write on an already-cancelled task closes the
    /// shared connection. Owned senders must keep that cancellation off the wire.
    private struct CancellationAwareStream: SpiceByteStream {
        let base: MemoryByteStream
        let probe: WriteProbe
        func send(_ bytes: [UInt8]) async throws {
            if Task.isCancelled {
                probe.recordCancelledWrite()
                await base.close()
                throw CancellationError()
            }
            try await base.send(bytes)
        }
        func receive(exactly count: Int) async throws -> [UInt8] { try await base.receive(exactly: count) }
        func close() async { await base.close() }
    }

    private func announce(_ caps: [AgentCapability], to server: ServerChannel) async throws {
        try await sendAgent(AgentMessage.announceCapabilities(request: false, capabilities: caps), to: server)
    }

    private func sendAgent(_ message: AgentMessage, to server: ServerChannel) async throws {
        for chunk in message.encodeChunks() { try await server.send(MainServerMessage.agentData.rawValue, chunk) }
    }

    private func grantTokens(_ server: ServerChannel) async throws {
        var writer = ByteWriter(); writer.writeU32(10_000)
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
