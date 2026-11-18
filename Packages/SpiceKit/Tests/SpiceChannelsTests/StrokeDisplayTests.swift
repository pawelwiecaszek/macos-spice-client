import Testing
@testable import SpiceChannels
import SpiceCodecs
import SpiceTransport
import SpiceWire

@Suite(.timeLimit(.minutes(1)))
struct StrokeDisplayTests {
    @Test func solidStrokeUpdatesPixelsThroughTheDisplayChannel() async throws {
        let result = try await replay(stroke())
        #expect(result.errors == 0)
        #expect(Array(result.surface.pixels.prefix(5)) == [0xFFFF_0000, 0xFFFF_0000, 0xFFFF_0000, 0xFFFF_0000, 0xFF00_0000])
        #expect(result.surface.pixels.dropFirst(5).allSatisfy { $0 == 0xFF00_0000 })
    }

    @Test func styledCubicPathsRejectWithoutPaintingAPartialFigure() async throws {
        for message in [stroke(styled: true, curve: true)] {
            let decoded = try DrawStroke(decoding: message.payload)
            #expect(decoded.attributes.style == [16, 16])
            #expect(decoded.path.segments.contains { $0.flags.contains(.bezier) })
            let result = try await replay(message)
            #expect(result.errors == 1)
            #expect(result.surface.pixels.allSatisfy { $0 == 0xFF00_0000 })
        }
    }

    @Test func mixedStraightAndCubicWireSegmentsRenderWithoutDecodeErrors() async throws {
        let result = try await replay(stroke(curve: true))
        #expect(result.errors == 0)
        #expect(result.surface.pixels.filter { $0 != 0xFF00_0000 }.count > 4)
        #expect(Array(result.surface.pixels.prefix(4)) == Array(repeating: 0xFFFF_0000, count: 4))
    }

    @Test func styledHorizontalWireStrokeUsesTransparentGaps() async throws {
        let result = try await replay(stroke(styled: true))
        #expect(result.errors == 0)
        #expect(Array(result.surface.pixels.prefix(5)) == [0xFFFF_0000, 0xFF00_0000, 0xFFFF_0000, 0xFF00_0000, 0xFF00_0000])
    }

    @Test func joinedDiagonalWireStrokePreservesRoundedPhase() async throws {
        let result = try await replay(stroke(styled: true, joined: true))
        #expect(result.errors == 0)
        #expect(result.surface.pixels.indices.filter { result.surface.pixels[$0] == 0xFFFF_0000 } == [0,8])
    }

    private func replay(_ message: SpiceMessage) async throws -> (surface: PixelBuffer, errors: Int) {
        let (client, server) = await MemoryByteStream.pair()
        let connection = ChannelConnection(type: .display, id: 0, stream: client, serverCaps: CapabilitySet())
        let (events, sink) = AsyncStream<DisplayEvent>.makeStream()
        let display = DisplayChannel(connection: connection, events: sink)
        let drain = Task { for await _ in events {} }
        let loop = Task { try await display.run() }
        var create = ByteWriter()
        create.writeU32(0); create.writeU32(5); create.writeU32(3)
        create.writeU32(SurfaceFormat.xRGB32.rawValue); create.writeU32(1)
        var ping = ByteWriter(); ping.writeU32(1); ping.writeU64(0)
        try await server.send(SpiceMessage(type: DisplayServerMessage.surfaceCreate.rawValue, payload: create.bytes).encode() +
            message.encode() + SpiceMessage(type: BaseServerMessage.ping.rawValue, payload: ping.bytes).encode())
        while true {
            let header = try MiniHeader(decoding: try await server.receive(exactly: MiniHeader.size))
            _ = try await server.receive(exactly: Int(header.size))
            if header.type == BaseClientMessage.pong.rawValue { break }
        }
        let result = try #require(await display.primarySurface())
        let errors = await display.decodeErrorCount
        await display.close(); loop.cancel(); drain.cancel(); _ = try? await loop.value
        return (result, errors)
    }

    private func stroke(styled: Bool = false, curve: Bool = false, joined: Bool = false) -> SpiceMessage {
        var writer = ByteWriter()
        writer.writeU32(0); writer.writeI32(0); writer.writeI32(0); writer.writeI32(3); writer.writeI32(5)
        writer.writeU8(0); writer.writeU32(styled ? 40 : 35)
        writer.writeU8(styled ? 8 : 0)
        if styled { writer.writeU8(2); writer.writeU32(0) }
        writer.writeU8(1); writer.writeU32(0x00FF_0000)
        writer.writeU16(Ropd.opPut.rawValue); writer.writeU16(0)
        writer.writeU32(curve ? 2 : 1)
        writer.writeU8(curve ? 1 : 3); writer.writeU32(joined ? 3 : 2)
        if joined {
            for point: (Int32, Int32) in [(0,0),(32,32),(64,0)] {
                writer.writeI32(point.0); writer.writeI32(point.1)
            }
        } else {
            writer.writeI32(0); writer.writeI32(0); writer.writeI32(64); writer.writeI32(0)
        }
        if curve {
            writer.writeU8(18); writer.writeU32(3)
            for point: (Int32, Int32) in [(64, 16), (32, 32), (0, 16)] {
                writer.writeI32(point.0); writer.writeI32(point.1)
            }
        }
        var bytes = writer.bytes
        if styled {
            var pointer = ByteWriter(); pointer.writeU32(UInt32(bytes.count))
            bytes.replaceSubrange(27..<31, with: pointer.bytes)
            var styles = ByteWriter(); styles.writeI32(16); styles.writeI32(16)
            bytes += styles.bytes
        }
        return SpiceMessage(type: DisplayServerMessage.drawStroke.rawValue, payload: bytes)
    }
}
