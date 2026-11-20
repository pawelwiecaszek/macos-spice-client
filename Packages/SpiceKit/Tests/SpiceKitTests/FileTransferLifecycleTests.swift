import Foundation
import Synchronization
import Testing
import SpiceKit

/// Exercises the public session API against a synthetic, fully linked agent.
/// No guest, audio/device access, real ticket, or network connection is needed.
@Suite("File transfer lifecycle", .timeLimit(.minutes(1)))
struct FileTransferLifecycleTests {
    @Test func cancellingInitialStatusWaitIgnoresLateAndDuplicateStatusesOnReplacement() async throws {
        try await withFixture { fixture in
            let cancelled = Task { try await fixture.session.sendFile(fixture.file) { _, _ in } }
            let first = try await fixture.server.nextAgent(.fileXferStart)
            let firstID = try transferID(first)
            cancelled.cancel()
            await expectCancellation(cancelled)
            // Cleanup is owned by an independent main-channel flusher, so the
            // peer can receive CANCEL after the cancelled caller has returned.
            let cancellation = try await fixture.server.nextAgent(.fileXferStatus)
            #expect(FileTransferCodec.decodeStatus(cancellation)?.id == firstID)
            #expect(FileTransferCodec.decodeStatus(cancellation)?.result == .cancelled)

            for result: FileTransferResult in [.success, .canSendData, .canSendData] {
                try await fixture.server.sendAgent(FileTransferCodec.status(id: firstID, result: result))
            }
            try await fixture.server.sendAgent(FileTransferCodec.status(id: .max, result: .success))
            _ = try await fixture.server.barrier()
            #expect(fixture.writeProbe.cancelledWrites == 0)

            let replacement = Task { try await fixture.session.sendFile(fixture.file) { _, _ in } }
            let secondID = try transferID(await fixture.server.nextAgent(.fileXferStart))
            #expect(secondID != firstID)
            try await fixture.server.sendAgent(FileTransferCodec.status(id: secondID, result: .canSendData))
            let data = try await fixture.server.nextAgent(.fileXferData)
            try expectFileData(data, id: secondID)
            // A repeated readiness response must not satisfy the final SUCCESS wait.
            try await fixture.server.sendAgent(FileTransferCodec.status(id: secondID, result: .canSendData))
            try await fixture.server.sendAgent(FileTransferCodec.status(id: secondID, result: .success))
            try await replacement.value
            #expect(try await fixture.server.barrier().allSatisfy { $0.knownType != .fileXferStart })
        }
    }

    @Test func cancellingFinalStatusWaitStopsWithoutDisconnectingTheAgent() async throws {
        try await withFixture { fixture in
            let transfer = Task { try await fixture.session.sendFile(fixture.file) { _, _ in } }
            let id = try transferID(await fixture.server.nextAgent(.fileXferStart))
            try await fixture.server.sendAgent(FileTransferCodec.status(id: id, result: .canSendData))
            try expectFileData(await fixture.server.nextAgent(.fileXferData), id: id)
            transfer.cancel()
            await expectCancellation(transfer)
            let cancellation = try await fixture.server.nextAgent(.fileXferStatus)
            #expect(FileTransferCodec.decodeStatus(cancellation)?.result == .cancelled)
            let remaining = try await fixture.server.barrier()
            #expect(remaining.allSatisfy { $0.knownType != .fileXferData })
            #expect(await fixture.session.clipboardSupported, "Cancellation must leave the agent connected")
            #expect(fixture.writeProbe.cancelledWrites == 0)
        }
    }

    @Test func unansweredInitialStatusTimesOutWithoutAutomaticallyRetryingStart() async throws {
        try await withFixture(timeout: .milliseconds(30)) { fixture in
            let transfer = Task { try await fixture.session.sendFile(fixture.file) { _, _ in } }
            let id = try transferID(await fixture.server.nextAgent(.fileXferStart))
            switch await transfer.result {
            case .success: Issue.record("An unanswered transfer must not complete")
            case .failure(let error): #expect(error as? SpiceSession.FileTransferError == .statusTimedOut)
            }
            let cancellation = try await fixture.server.nextAgent(.fileXferStatus)
            #expect(FileTransferCodec.decodeStatus(cancellation)?.id == id)
            #expect(FileTransferCodec.decodeStatus(cancellation)?.result == .cancelled)
            let remaining = try await fixture.server.barrier()
            #expect(remaining.allSatisfy { $0.knownType != .fileXferStart && $0.knownType != .fileXferData })
        }
    }

    @Test func agentDisconnectWakesAWaitingTransfer() async throws {
        try await withFixture { fixture in
            let transfer = Task { try await fixture.session.sendFile(fixture.file) { _, _ in } }
            _ = try await fixture.server.nextAgent(.fileXferStart)
            try await fixture.server.send(MainServerMessage.agentDisconnected.rawValue, [0, 0, 0, 0])
            switch await transfer.result {
            case .success: Issue.record("A transfer must fail when the agent disconnects")
            case .failure(let error):
                #expect(error as? SpiceSession.FileTransferError == .rejected(.agentNotConnected))
            }
        }
    }

    @Test func zeroByteTransferAcceptsBackToBackReadinessAndSuccessWithoutData() async throws {
        try await withFixture { fixture in
            try Data().write(to: fixture.file)
            let transfer = Task { try await fixture.session.sendFile(fixture.file) { _, _ in } }
            let id = try transferID(await fixture.server.nextAgent(.fileXferStart))
            let ready = FileTransferCodec.status(id: id, result: .canSendData)
            let success = FileTransferCodec.status(id: id, result: .success)
            // Both complete agent messages arrive in one SPICE payload. The
            // session must retain terminal status even if it precedes final wait.
            let payload = ready.encodeChunks().flatMap { $0 } + success.encodeChunks().flatMap { $0 }
            try await fixture.server.send(MainServerMessage.agentData.rawValue, payload)
            try await transfer.value
            let remaining = try await fixture.server.barrier()
            #expect(remaining.allSatisfy { $0.knownType != .fileXferData && $0.knownType != .fileXferStart })
        }
    }

    @Test func activeTransferLimitRejectsSeventeenthStartAndCancelledSlotsAreReleased() async throws {
        try await withFixture { fixture in
            var transfers: [Task<Void, any Error>] = []
            var ids: Set<UInt32> = []
            for _ in 0..<16 {
                transfers.append(Task { try await fixture.session.sendFile(fixture.file) { _, _ in } })
                let start = try await fixture.server.nextAgent(.fileXferStart)
                let inserted = ids.insert(try transferID(start)).inserted
                #expect(inserted)
            }
            do {
                try await fixture.session.sendFile(fixture.file) { _, _ in }
                Issue.record("A seventeenth active transfer must be refused")
            } catch {
                #expect(error as? SpiceSession.FileTransferError == .transferLimit)
            }
            let extra = try await fixture.server.barrier()
            #expect(extra.allSatisfy { $0.knownType != .fileXferStart })
            for transfer in transfers { transfer.cancel() }
            for transfer in transfers { await expectCancellation(transfer) }
            var cancelledIDs: Set<UInt32> = []
            for _ in 0..<16 {
                let message = try await fixture.server.nextAgent(.fileXferStatus)
                let status = try #require(FileTransferCodec.decodeStatus(message))
                #expect(status.result == .cancelled)
                cancelledIDs.insert(status.id)
            }
            #expect(cancelledIDs == ids)
            #expect(fixture.writeProbe.cancelledWrites == 0)

            // Retiring cancelled senders releases their active-slot reservations.
            let replacement = Task { try await fixture.session.sendFile(fixture.file) { _, _ in } }
            let id = try transferID(await fixture.server.nextAgent(.fileXferStart))
            #expect(!ids.contains(id))
            try await fixture.server.sendAgent(FileTransferCodec.status(id: id, result: .canSendData))
            try expectFileData(await fixture.server.nextAgent(.fileXferData), id: id)
            try await fixture.server.sendAgent(FileTransferCodec.status(id: id, result: .success))
            try await replacement.value
        }
    }

    @Test func growthAfterStartSendsOnlyTheOriginallyAnnouncedPrefix() async throws {
        try await withFixture { fixture in
            let transfer = Task { try await fixture.session.sendFile(fixture.file) { _, _ in } }
            let start = try await fixture.server.nextAgent(.fileXferStart)
            let id = try transferID(start)
            let metadata = String(decoding: start.data.dropFirst(4), as: UTF8.self)
            #expect(metadata.contains("\nsize=\(Self.contents.count)\n"))
            let writer = try FileHandle(forWritingTo: fixture.file)
            do {
                _ = try writer.seekToEnd()
                try writer.write(contentsOf: Data("appended after START".utf8))
                try writer.close()
            } catch {
                try? writer.close()
                throw error
            }
            #expect(try Data(contentsOf: fixture.file).count > Self.contents.count)
            try await fixture.server.sendAgent(FileTransferCodec.status(id: id, result: .canSendData))
            try expectFileData(await fixture.server.nextAgent(.fileXferData), id: id)
            try await fixture.server.sendAgent(FileTransferCodec.status(id: id, result: .success))
            try await transfer.value
            let remaining = try await fixture.server.barrier()
            #expect(remaining.allSatisfy { $0.knownType != .fileXferData })
        }
    }

    private func expectCancellation(_ task: Task<Void, any Error>) async {
        switch await task.result {
        case .success: Issue.record("Cancelled file transfer unexpectedly completed")
        case .failure(let error): #expect(error is CancellationError)
        }
    }

    private func transferID(_ message: AgentMessage) throws -> UInt32 {
        var reader = ByteReader(message.data)
        return try reader.readU32()
    }

    private func expectFileData(_ message: AgentMessage, id: UInt32) throws {
        var reader = ByteReader(message.data)
        #expect(try reader.readU32() == id)
        #expect(try reader.readU64() == UInt64(Self.contents.count))
        #expect(try Array(reader.readBytes(reader.remaining)) == Self.contents)
    }

    private static let contents = Array("synthetic transfer\n".utf8)
    private struct Fixture: Sendable {
        let session: SpiceSession
        let server: AgentServer
        let file: URL
        let writeProbe: WriteProbe
    }

    private func withFixture(timeout: Duration = .seconds(30),
                             operation: (Fixture) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spice-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.txt")
        try Data(Self.contents).write(to: file)
        let connector = Connector()
        var profile = ConnectionProfile(host: "file.example.invalid")
        profile.port = 5900
        let session = SpiceSession(profile: profile, connector: connector, encryptor: Encryptor(),
                                   fileTransferStatusTimeout: timeout)
        let connected = Task {
            for await event in session.events {
                if case .state(.connected) = event { return }
            }
            throw FixtureError.closed
        }
        async let accepted = AgentServer.accept(await connector.accept())
        await session.connect()
        do {
            let server = try await accepted
            var main = ByteWriter()
            for value: UInt32 in [77, 0, 1, 1, 1, 1000, 0, 0] { main.writeU32(value) }
            try await server.send(MainServerMessage.initialize.rawValue, main.bytes)
            _ = try await server.expect(MainClientMessage.attachChannels.rawValue)
            try await server.send(MainServerMessage.channelsList.rawValue, [0, 0, 0, 0])
            try await connected.value
            try await server.sendAgent(.announceCapabilities(request: false, capabilities: [.clipboardByDemand]))
            _ = try await server.barrier()
            var capabilitiesObserved = false
            for _ in 0..<10_000 {
                if await session.clipboardSupported { capabilitiesObserved = true; break }
                await Task.yield()
            }
            guard capabilitiesObserved else { throw FixtureError.agentNotReady }
            try await operation(Fixture(session: session, server: server, file: file, writeProbe: connector.writeProbe))
        } catch {
            connected.cancel()
            await session.disconnect()
            throw error
        }
        connected.cancel()
        await session.disconnect()
    }

    private enum FixtureError: Error { case closed, agentNotReady }
    private struct Encryptor: TicketEncryptor {
        func encrypt(_ plaintext: [UInt8], subjectPublicKeyInfo: [UInt8]) throws -> [UInt8] {
            [UInt8](repeating: 7, count: 128)
        }
    }

    private actor Connector: StreamConnector {
        nonisolated let writeProbe = WriteProbe()
        private var streams: [MemoryByteStream] = []
        private var waiter: CheckedContinuation<MemoryByteStream, Never>?
        nonisolated func connect(to endpoint: SpiceEndpoint, route: SpiceEndpoint.Route) async throws -> any SpiceByteStream {
            let (client, server) = await MemoryByteStream.pair()
            await enqueue(server)
            return CancellationAwareStream(base: client, probe: writeProbe)
        }
        private func enqueue(_ stream: MemoryByteStream) {
            if let waiter { self.waiter = nil; waiter.resume(returning: stream) }
            else { streams.append(stream) }
        }
        func accept() async -> MemoryByteStream {
            if !streams.isEmpty { return streams.removeFirst() }
            return await withCheckedContinuation { waiter = $0 }
        }
    }

    private final class WriteProbe: Sendable {
        private let count = Mutex(0)
        var cancelledWrites: Int { count.withLock { $0 } }
        func recordCancelledWrite() { count.withLock { $0 += 1 } }
    }

    /// Models the transport's cancellation behavior: writing on the cancelled
    /// transfer task closes the shared channel rather than silently succeeding.
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
        func receive(exactly count: Int) async throws -> [UInt8] {
            try await base.receive(exactly: count)
        }
        func close() async { await base.close() }
    }

    private actor AgentServer {
        let stream: MemoryByteStream
        private var assembler = AgentMessageAssembler()
        private var messages: [AgentMessage] = []
        init(stream: MemoryByteStream) { self.stream = stream }

        static func accept(_ stream: MemoryByteStream) async throws -> AgentServer {
            let header = try LinkHeader(decoding: await stream.receive(exactly: 16))
            _ = try await stream.receive(exactly: Int(header.bodySize))
            var reply = ByteWriter()
            reply.writeU32(0); reply.writeBytes([UInt8](repeating: 0, count: 162))
            reply.writeU32(1); reply.writeU32(0); reply.writeU32(4 + 162 + 12)
            reply.writeU32(CapabilitySet(bits: [0, 1, 3]).words[0])
            var linked = ByteWriter()
            linked.writeU32(spiceMagic); linked.writeU32(2); linked.writeU32(2)
            linked.writeU32(UInt32(reply.count)); linked.writeBytes(reply.bytes)
            try await stream.send(linked.bytes)
            _ = try await stream.receive(exactly: 4)
            _ = try await stream.receive(exactly: 128)
            try await stream.send([0, 0, 0, 0])
            return AgentServer(stream: stream)
        }

        func send(_ type: UInt16, _ payload: [UInt8]) async throws {
            try await stream.send(SpiceMessage(type: type, payload: payload).encode())
        }
        func sendAgent(_ message: AgentMessage) async throws {
            for chunk in message.encodeChunks() { try await send(MainServerMessage.agentData.rawValue, chunk) }
        }
        private func receive() async throws -> SpiceMessage {
            let header = try MiniHeader(decoding: await stream.receive(exactly: 6))
            return SpiceMessage(type: header.type, payload: try await stream.receive(exactly: Int(header.size)))
        }
        func expect(_ type: UInt16) async throws -> SpiceMessage {
            while true {
                let message = try await receive()
                if message.type == type { return message }
            }
        }
        func nextAgent(_ type: AgentMessageType) async throws -> AgentMessage {
            while true {
                if let index = messages.firstIndex(where: { $0.knownType == type }) { return messages.remove(at: index) }
                let message = try await receive()
                if message.type == MainClientMessage.agentData.rawValue { messages += try assembler.feed(message.payload) }
            }
        }
        func barrier() async throws -> [AgentMessage] {
            var ping = ByteWriter(); ping.writeU32(1); ping.writeU64(0)
            try await send(BaseServerMessage.ping.rawValue, ping.bytes)
            while true {
                let message = try await receive()
                if message.type == BaseClientMessage.pong.rawValue {
                    let result = messages; messages.removeAll(); return result
                }
                if message.type == MainClientMessage.agentData.rawValue { messages += try assembler.feed(message.payload) }
            }
        }
    }
}
