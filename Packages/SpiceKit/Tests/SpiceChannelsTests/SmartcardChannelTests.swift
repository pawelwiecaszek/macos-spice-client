import Testing
@testable import SpiceChannels
import SpiceTransport
import SpiceWire

/// A card that answers every APDU with its reversed bytes plus 90 00.
actor FakeCard: SmartcardCard {
    nonisolated let displayName = "Fake Card"
    private(set) var connected = false
    private(set) var received: [[UInt8]] = []

    func connect() async throws -> [UInt8] {
        connected = true
        return [0x3B, 0x8C, 0x80, 0x01]
    }

    func transmit(_ apdu: [UInt8]) async throws -> [UInt8] {
        received.append(apdu)
        return apdu.reversed() + [0x90, 0x00]
    }

    func disconnect() async { connected = false }
}

/// Server side of a smartcard channel (mini header, VSC payloads).
struct SmartcardServer {
    let stream: MemoryByteStream

    func read() async throws -> VSCMessage {
        var header = ByteReader(try await stream.receive(exactly: 6))
        let type = try header.readU16()
        let size = Int(try header.readU32())
        #expect(type == 101)
        return try VSCMessage(decoding: try await stream.receive(exactly: size))
    }

    func write(_ message: VSCMessage) async throws {
        try await stream.send(message.encode().encode())
    }
}

@Suite("Smartcard channel")
struct SmartcardChannelTests {
    @Test func wireFormatIsLittleEndian() throws {
        let message = VSCMessage(.atr, readerID: 2, data: [0xAA, 0xBB]).encode()
        #expect(message.type == 101)
        #expect(message.payload == [5, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 0xAA, 0xBB])
        #expect(try VSCMessage(decoding: message.payload) == VSCMessage(.atr, readerID: 2, data: [0xAA, 0xBB]))
    }

    @Test func rejectsTruncatedAndOversizedPayloads() {
        #expect(throws: WireError.self) { try VSCMessage(decoding: [7, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 1]) }
        var w = ByteWriter()
        w.writeU32(7); w.writeU32(0); w.writeU32(UInt32(VSCMessage.maxPayload + 1))
        #expect(throws: WireError.self) { try VSCMessage(decoding: w.bytes) }
    }

    @Test func insertTransmitAndRemove() async throws {
        let (client, serverStream) = await MemoryByteStream.pair()
        let server = SmartcardServer(stream: serverStream)
        let connection = ChannelConnection(type: .smartcard, id: 0, stream: client, serverCaps: CapabilitySet(bits: []))
        let (events, sink) = AsyncStream<SmartcardEvent>.makeStream()
        let channel = SmartcardChannel(connection: connection, events: sink)
        let loop = Task { try await channel.run() }
        let card = FakeCard()

        let insert = Task { try await channel.insert(card) }
        let add = try await server.read()
        #expect(add.type == .readerAdd)
        #expect(add.readerID == VSCMessage.undefinedReaderID)
        try await server.write(.error(.success, readerID: 4))

        let atr = try await server.read()
        #expect(atr == VSCMessage(.atr, readerID: 4, data: [0x3B, 0x8C, 0x80, 0x01]))
        try await insert.value
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .inserted(name: "Fake Card"))

        try await server.write(VSCMessage(.apdu, readerID: 4, data: [0x00, 0xA4, 0x04, 0x00]))
        let reply = try await server.read()
        #expect(reply == VSCMessage(.apdu, readerID: 4, data: [0x00, 0x04, 0xA4, 0x00, 0x90, 0x00]))

        try await server.write(VSCMessage(.flush, readerID: 4))
        #expect(try await server.read().type == .flushComplete)

        await channel.remove()
        #expect(try await server.read() == VSCMessage(.cardRemove, readerID: 4))
        #expect(await iterator.next() == .removed)
        #expect(await card.connected == false)
        #expect(await card.received == [[0x00, 0xA4, 0x04, 0x00]])
        loop.cancel()
        await channel.close()
    }

    @Test func readerRejectedByServer() async throws {
        let (client, serverStream) = await MemoryByteStream.pair()
        let server = SmartcardServer(stream: serverStream)
        let connection = ChannelConnection(type: .smartcard, id: 0, stream: client, serverCaps: CapabilitySet(bits: []))
        let (_, sink) = AsyncStream<SmartcardEvent>.makeStream()
        let channel = SmartcardChannel(connection: connection, events: sink)
        let loop = Task { try await channel.run() }
        let insert = Task { try await channel.insert(FakeCard()) }
        _ = try await server.read()
        try await server.write(.error(.cannotAddMoreReaders, readerID: VSCMessage.undefinedReaderID))
        await #expect(throws: SmartcardError.readerNotAccepted) { try await insert.value }
        loop.cancel()
        await channel.close()
    }
}
