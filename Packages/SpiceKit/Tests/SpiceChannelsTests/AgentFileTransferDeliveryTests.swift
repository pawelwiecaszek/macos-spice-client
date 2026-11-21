import Testing
@testable import SpiceChannels
import SpiceAgent
import SpiceTransport
import SpiceWire

@Suite("Agent file transfer delivery", .timeLimit(.minutes(1)))
struct AgentFileTransferDeliveryTests {
    @Test func agentReplacementDropsQueuedMessagesAndRejectsOldProducers() async throws {
        try await withMain { main, server in
            let old = try #require(await main.fileTransferAuthorization)
            try await main.enqueueFileTransfer(FileTransferCodec.start(id: 1, name: "old.txt", size: 3), authorization: old)
            try await main.enqueueFileTransfer(FileTransferCodec.data(id: 1, bytes: [1, 2, 3][...]), authorization: old)

            try await server.send(MainServerMessage.agentDisconnected.rawValue, [])
            _ = try await barrier(server)
            try await server.send(MainServerMessage.agentConnectedTokens.rawValue, [0, 0, 0, 0])
            _ = try await server.expect(MainClientMessage.agentStart.rawValue)
            _ = try await barrier(server)

            await expectUnavailable {
                try await main.enqueueFileTransfer(FileTransferCodec.data(id: 1, bytes: [4][...]), authorization: old)
            }
            await expectUnavailable { try await main.cancelFileTransfer(id: 1, authorization: old) }

            let current = try #require(await main.fileTransferAuthorization)
            try await main.enqueueFileTransfer(FileTransferCodec.start(id: 2, name: "new.txt", size: 0), authorization: current)
            try await grantTokens(server)
            let messages = try await barrier(server)
            let starts = messages.filter { $0.knownType == .fileXferStart }
            #expect(starts.count == 1)
            #expect(try transferID(#require(starts.first)) == 2)
            #expect(messages.allSatisfy { $0.knownType != .fileXferData && $0.knownType != .fileXferStatus })
        }
    }

    @Test func freshDisabledCapabilityDropsBulkButAllowsCancellationCleanup() async throws {
        try await withMain { main, server in
            let authorization = try #require(await main.fileTransferAuthorization)
            for id: UInt32 in [7, 8] {
                try await main.enqueueFileTransfer(FileTransferCodec.start(id: id, name: "queued.txt", size: 1), authorization: authorization)
                try await main.enqueueFileTransfer(FileTransferCodec.data(id: id, bytes: [0x5A][...]), authorization: authorization)
            }
            for chunk in AgentMessage.announceCapabilities(request: false, capabilities: [.fileXferDisabled]).encodeChunks() {
                try await server.send(MainServerMessage.agentData.rawValue, chunk)
            }
            _ = try await barrier(server)
            do {
                try await main.enqueueFileTransfer(FileTransferCodec.data(id: 8, bytes: [0x5A][...]), authorization: authorization)
                Issue.record("Fresh guest policy must reject bulk admission before UI notification handling")
            } catch AgentFileTransferAdmissionError.disabledByGuest { }
            catch { Issue.record("Expected disabledByGuest, got \(error)") }

            try await main.cancelFileTransfer(id: 7, authorization: authorization)
            try await grantTokens(server)
            let messages = try await barrier(server)
            // ID 7 was removed by cancellation. ID 8 must also be dropped by
            // the send-time policy gate, despite having been queued earlier.
            #expect(messages.allSatisfy { $0.knownType != .fileXferStart && $0.knownType != .fileXferData })
            let cancellations = messages.compactMap(FileTransferCodec.decodeStatus)
            #expect(cancellations.count == 1 && cancellations.first?.id == 7)
            #expect(cancellations.first?.result == .cancelled)
        }
    }

    @Test func boundedQueueReservesCleanupAndCancellingRemovesUnsentData() async throws {
        try await withMain { main, server in
            let authorization = try #require(await main.fileTransferAuthorization)
            let bytes = [UInt8](repeating: 0x5A, count: FileTransferCodec.chunkSize)
            let cancelledData = FileTransferCodec.data(id: 7, bytes: bytes[...])
            for _ in 0..<64 { try await main.enqueueFileTransfer(cancelledData, authorization: authorization) }
            await expectQueueFull { try await main.enqueueFileTransfer(cancelledData, authorization: authorization) }
            let beforeCancellation = await main.pendingAgentBytes
            #expect(beforeCancellation <= MainChannel.maxAgentOutboxBytes)

            try await main.cancelFileTransfer(id: 7, authorization: authorization)
            #expect(await main.pendingAgentBytes < beforeCancellation)
            let retainedData = FileTransferCodec.data(id: 8, bytes: bytes[...])
            for _ in 0..<63 { try await main.enqueueFileTransfer(retainedData, authorization: authorization) }
            await expectQueueFull { try await main.enqueueFileTransfer(retainedData, authorization: authorization) }
            // The normal queue is full. An unrelated cleanup control still has
            // reserved capacity and must not force a cancelled producer to write.
            try await main.cancelFileTransfer(id: 99, authorization: authorization)
            #expect(await main.pendingAgentBytes <= MainChannel.maxAgentOutboxBytes)

            try await grantTokens(server)
            let messages = try await barrier(server)
            let data = messages.filter { $0.knownType == .fileXferData }
            #expect(data.count == 63)
            for message in data { #expect(try transferID(message) == 8) }
            let cancellations = messages.compactMap(FileTransferCodec.decodeStatus)
            #expect(cancellations.count == 2)
            #expect(Set(cancellations.map(\.id)) == [7, 99])
            #expect(cancellations.allSatisfy { $0.result == .cancelled })
        }
    }

    private func withMain(operation: (MainChannel, ServerChannel) async throws -> Void) async throws {
        let (client, stream) = await MemoryByteStream.pair()
        let server = ServerChannel(stream: stream)
        let connection = ChannelConnection(type: .main, id: 0, stream: client, serverCaps: MainChannel.capabilities)
        let (_, sink) = AsyncStream<MainEvent>.makeStream()
        let main = MainChannel(connection: connection, events: sink)
        let loop = Task { try await main.run() }
        do {
            try await server.send(MainServerMessage.agentConnectedTokens.rawValue, [0, 0, 0, 0])
            _ = try await server.expect(MainClientMessage.agentStart.rawValue)
            _ = try await barrier(server)
            try await operation(main, server)
        } catch {
            loop.cancel(); await main.close(); _ = await loop.result
            throw error
        }
        loop.cancel(); await main.close(); _ = await loop.result
    }

    private func expectUnavailable(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("An old agent authorization must be rejected")
        } catch AgentFileTransferAdmissionError.unavailable { }
        catch { Issue.record("Expected unavailable, got \(error)") }
    }

    private func expectQueueFull(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("The bounded queue must refuse additional bulk messages")
        } catch AgentFileTransferAdmissionError.queueFull { }
        catch { Issue.record("Expected queueFull, got \(error)") }
    }

    private func transferID(_ message: AgentMessage) throws -> UInt32 {
        var reader = ByteReader(message.data)
        return try reader.readU32()
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
