import Foundation
import Testing
import SpiceCodecs
@testable import SpiceChannels
import SpiceTransport
import SpiceWire

/// Returns 128 bytes so tests don't need real RSA.
struct FakeEncryptor: TicketEncryptor {
    func encrypt(_ plaintext: [UInt8], subjectPublicKeyInfo: [UInt8]) throws -> [UInt8] {
        [UInt8](repeating: 7, count: 128)
    }
}

/// Hands out in-memory streams and lets the test act as the server for each channel.
actor FakeConnector: StreamConnector {
    private var serverSides: [MemoryByteStream] = []
    private var waiters: [CheckedContinuation<MemoryByteStream, Never>] = []

    nonisolated func connect(to endpoint: SpiceEndpoint, route: SpiceEndpoint.Route) async throws -> any SpiceByteStream {
        let (client, server) = await MemoryByteStream.pair()
        await enqueue(server)
        return client
    }

    private func enqueue(_ server: MemoryByteStream) {
        if waiters.isEmpty {
            serverSides.append(server)
        } else {
            waiters.removeFirst().resume(returning: server)
        }
    }

    /// Next server-side stream (in connection order).
    func accept() async -> MemoryByteStream {
        if !serverSides.isEmpty { return serverSides.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

/// Server-side helpers speaking the mini-header protocol.
struct ServerChannel {
    let stream: MemoryByteStream
    var type: ChannelType = .main
    var connectionID: UInt32 = 0

    /// Completes the link handshake; returns the requested channel type.
    static func accept(_ stream: MemoryByteStream) async throws -> ServerChannel {
        let header = try LinkHeader(decoding: try await stream.receive(exactly: 16))
        let body = try await stream.receive(exactly: Int(header.bodySize))
        var r = ByteReader(body)
        let connectionID = try r.readU32()
        let type = ChannelType(rawValue: try r.readU8()) ?? .main

        var reply = ByteWriter()
        reply.writeU32(0)
        reply.writeBytes([UInt8](repeating: 0, count: 162))
        reply.writeU32(1)
        reply.writeU32(1)
        reply.writeU32(4 + 162 + 12)
        reply.writeU32(CapabilitySet(bits: [0, 1, 3]).words[0])
        reply.writeU32(CapabilitySet(bits: [DisplayCapability.prefCompression.rawValue]).words[0])
        var out = ByteWriter()
        out.writeU32(spiceMagic); out.writeU32(2); out.writeU32(2); out.writeU32(UInt32(reply.count))
        out.writeBytes(reply.bytes)
        try await stream.send(out.bytes)
        _ = try await stream.receive(exactly: 4)  // auth mechanism
        _ = try await stream.receive(exactly: 128)  // ticket
        try await stream.send([0, 0, 0, 0])
        return ServerChannel(stream: stream, type: type, connectionID: connectionID)
    }

    func send(_ type: UInt16, _ payload: [UInt8]) async throws {
        try await stream.send(SpiceMessage(type: type, payload: payload).encode())
    }

    func receive() async throws -> SpiceMessage {
        let header = try MiniHeader(decoding: try await stream.receive(exactly: 6))
        return SpiceMessage(type: header.type, payload: try await stream.receive(exactly: Int(header.size)))
    }

    /// Receives until a message of `type` arrives.
    func expect(_ type: UInt16) async throws -> SpiceMessage {
        while true {
            let message = try await receive()
            if message.type == type { return message }
        }
    }
}

@Suite("Channels end-to-end (in-memory server)", .timeLimit(.minutes(1)))
struct SessionFlowTests {
    func makeOpener(_ connector: FakeConnector) -> ChannelOpener {
        ChannelOpener(endpoint: SpiceEndpoint(host: "test", port: 5900), connector: connector,
                      encryptor: FakeEncryptor(), ticket: { Array("t".utf8) })
    }

    @Test func mainChannelHandshake() async throws {
        let connector = FakeConnector()
        let opener = makeOpener(connector)
        async let serverTask: ServerChannel = ServerChannel.accept(await connector.accept())
        let connection = try await opener.open(type: .main, id: 0, connectionID: 0, channelCaps: MainChannel.capabilities)
        let server = try await serverTask
        #expect(server.type == .main)

        let (events, sink) = AsyncStream<MainEvent>.makeStream()
        let main = MainChannel(connection: connection, events: sink)
        let runTask = Task { try await main.run() }

        // SET_ACK window 2, then PING, then INIT.
        var ack = ByteWriter(); ack.writeU32(5); ack.writeU32(2)
        try await server.send(BaseServerMessage.setAck.rawValue, ack.bytes)
        let ackSync = try await server.expect(BaseClientMessage.ackSync.rawValue)
        #expect(ackSync.payload == [5, 0, 0, 0])

        var ping = ByteWriter(); ping.writeU32(9); ping.writeU64(1234)
        try await server.send(BaseServerMessage.ping.rawValue, ping.bytes)
        let pong = try await server.expect(BaseClientMessage.pong.rawValue)
        var pongReader = ByteReader(pong.payload)
        #expect(try pongReader.readU32() == 9)

        var initMessage = ByteWriter()
        for value: UInt32 in [77, 1, 3, 1, 0, 0, 0, 0] { initMessage.writeU32(value) }
        try await server.send(MainServerMessage.initialize.rawValue, initMessage.bytes)
        _ = try await server.expect(MainClientMessage.attachChannels.rawValue)
        let modeRequest = try await server.expect(MainClientMessage.mouseModeRequest.rawValue)
        #expect(modeRequest.payload == [2, 0], "client mode must be requested when offered")

        var list = ByteWriter()
        list.writeU32(3)
        for (type, id) in [(ChannelType.display, 0), (.inputs, 0), (.cursor, 0)] {
            list.writeU8(type.rawValue); list.writeU8(UInt8(id))
        }
        try await server.send(MainServerMessage.channelsList.rawValue, list.bytes)

        var iterator = events.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == .initialized(sessionID: 77, mouseModes: [.server, .client], currentMode: .server, agentConnected: false))
        let second = await iterator.next()
        if case .channels(let channels) = second {
            #expect(channels.compactMap(\.type) == [.display, .inputs, .cursor])
        } else {
            Issue.record("expected channel list, got \(String(describing: second))")
        }
        runTask.cancel()
        await main.close()
    }

    @Test func displayChannelDrawsAndPublishesUpdates() async throws {
        let connector = FakeConnector()
        let opener = makeOpener(connector)
        async let serverTask: ServerChannel = ServerChannel.accept(await connector.accept())
        let connection = try await opener.open(type: .display, id: 0, connectionID: 77, channelCaps: DisplayChannel.capabilities)
        let server = try await serverTask
        #expect(server.connectionID == 77)

        let (events, sink) = AsyncStream<DisplayEvent>.makeStream()
        let display = DisplayChannel(connection: connection, events: sink)
        let runTask = Task { try await display.run() }

        let initMessage = try await server.expect(DisplayClientMessage.initialize.rawValue)
        #expect(initMessage.payload.count == 14)
        let preferred = try await server.expect(DisplayClientMessage.preferredCompression.rawValue)
        #expect(preferred.payload == [ImageCompression.autoGLZ.rawValue])

        // Primary surface 8x4.
        var create = ByteWriter()
        for value: UInt32 in [0, 8, 4, SurfaceFormat.xRGB32.rawValue, 1] { create.writeU32(value) }
        try await server.send(DisplayServerMessage.surfaceCreate.rawValue, create.bytes)

        // DRAW_FILL red over (2,1)-(6,3).
        var fill = ByteWriter()
        fill.writeU32(0)
        for v: Int32 in [1, 2, 3, 6] { fill.writeI32(v) }  // top, left, bottom, right
        fill.writeU8(0)  // no clip
        fill.writeU8(1); fill.writeU32(0x00FF_0000)  // solid brush
        fill.writeU16(Ropd.opPut.rawValue)
        fill.writeU8(0); fill.writeI32(0); fill.writeI32(0); fill.writeU32(0)  // no mask
        try await server.send(DisplayServerMessage.drawFill.rawValue, fill.bytes)

        // DRAW_COPY of a QUIC image from the golden fixtures, cached with CACHE_ME, then FROM_CACHE.
        let quicURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/codecs/quic-rgb32-1x1.bin")
        let quic = Array(try Data(contentsOf: quicURL))
        func copyMessage(imageType: ImageType, flags: ImageFlags, payload: [UInt8], x: Int32) -> [UInt8] {
            var w = ByteWriter()
            w.writeU32(0)
            for v: Int32 in [0, x, 1, x + 1] { w.writeI32(v) }
            w.writeU8(0)
            let pointerAt = w.count
            w.writeU32(0)
            for v: Int32 in [0, 0, 1, 1] { w.writeI32(v) }
            w.writeU16(Ropd.opPut.rawValue)
            w.writeU8(ScaleMode.nearest.rawValue)
            w.writeU8(0); w.writeI32(0); w.writeI32(0); w.writeU32(0)
            let imageAt = UInt32(w.count)
            w.writeU64(0xCAFE); w.writeU8(imageType.rawValue); w.writeU8(flags.rawValue); w.writeU32(1); w.writeU32(1)
            w.writeBytes(payload)
            var bytes = w.bytes
            bytes[pointerAt] = UInt8(imageAt & 0xFF)
            bytes[pointerAt + 1] = UInt8(imageAt >> 8)
            return bytes
        }
        var quicPayload = ByteWriter()
        quicPayload.writeU32(UInt32(quic.count))
        quicPayload.writeBytes(quic)
        try await server.send(DisplayServerMessage.drawCopy.rawValue,
                              copyMessage(imageType: .quic, flags: .cacheMe, payload: quicPayload.bytes, x: 0))
        try await server.send(DisplayServerMessage.drawCopy.rawValue,
                              copyMessage(imageType: .fromCache, flags: [], payload: [], x: 7))

        // Scroll the first row up by... copy (2,1) to (0,0) with COPY_BITS.
        var bits = ByteWriter()
        bits.writeU32(0)
        for v: Int32 in [3, 0, 4, 1] { bits.writeI32(v) }
        bits.writeU8(0)
        bits.writeI32(2); bits.writeI32(1)
        try await server.send(DisplayServerMessage.copyBits.rawValue, bits.bytes)

        var created = false
        var updates = 0
        for await event in events {
            switch event {
            case .primarySurfaceCreated(_, let w, let h):
                #expect(w == 8 && h == 4)
                created = true
            case .update:
                updates += 1
            default:
                break
            }
            if let surface = await display.primarySurface(), surface[0, 3] == 0xFFFF_0000 { break }
        }
        #expect(created)
        #expect(updates >= 1)
        let surface = try #require(await display.primarySurface())
        #expect(surface[2, 1] == 0xFFFF_0000)
        #expect(surface[5, 2] == 0xFFFF_0000)
        #expect(surface[6, 2] == 0xFF00_0000)
        let quicPixel: UInt32 = 0xFFFB_66D1  // see Fixtures/codecs (quic-rgb32-1x1)
        #expect(surface[0, 0] == quicPixel)
        #expect(surface[7, 0] == quicPixel, "FROM_CACHE must reuse the cached image")
        #expect(surface[0, 3] == 0xFFFF_0000, "COPY_BITS copied the red pixel")
        runTask.cancel()
        await display.close()
    }

    @Test func inputsThrottleMotionUntilAck() async throws {
        let connector = FakeConnector()
        let opener = makeOpener(connector)
        async let serverTask: ServerChannel = ServerChannel.accept(await connector.accept())
        let connection = try await opener.open(type: .inputs, id: 0, connectionID: 1, channelCaps: InputsChannel.capabilities)
        let server = try await serverTask
        let inputs = InputsChannel(connection: connection)
        let runTask = Task { try await inputs.run() }

        try await inputs.send(.keyDown(0x148))
        let key = try await server.expect(InputsClientMessage.keyDown.rawValue)
        #expect(key.payload == [0xE0, 0x48, 0, 0])

        for x in 0..<20 {
            try await inputs.send(.position(x: UInt32(x), y: 0, buttons: [], display: 0))
        }
        // Only 2 × ACK_BUNCH positions may be outstanding.
        for _ in 0..<8 { _ = try await server.expect(InputsClientMessage.mousePosition.rawValue) }
        try await server.send(InputsServerMessage.mouseMotionAck.rawValue, [])
        let flushed = try await server.expect(InputsClientMessage.mousePosition.rawValue)
        var reader = ByteReader(flushed.payload)
        #expect(try reader.readU32() == 19, "after an ack, the latest position is sent")
        runTask.cancel()
        await inputs.close()
    }

    @Test func cursorShapes() {
        let header = CursorHeader(unique: 1, rawType: CursorType.alpha.rawValue, width: 1, height: 1, hotSpotX: 0, hotSpotY: 0)
        let image = CursorDecoder.decode(header: header, data: [0xFF, 0x00, 0x00, 0x80][...])
        #expect(image?.image.pixels == [0x8000_0080])  // premultiplied blue at 50% alpha

        let mono = CursorHeader(unique: 2, rawType: CursorType.mono.rawValue, width: 2, height: 1, hotSpotX: 1, hotSpotY: 0)
        // AND = 0b01, XOR = 0b11 → pixel0 white (and 0, xor 1), pixel1 inverted→black.
        let monoImage = CursorDecoder.decode(header: mono, data: [0b0100_0000, 0b1100_0000][...])
        #expect(monoImage?.image.pixels == [0xFFFF_FFFF, 0xFF00_0000])
        #expect(monoImage?.hotSpotX == 1)
    }
}
