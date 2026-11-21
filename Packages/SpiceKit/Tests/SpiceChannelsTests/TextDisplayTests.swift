import Testing
@testable import SpiceChannels
import SpiceCodecs
import SpiceTransport
import SpiceWire

@Suite(.timeLimit(.minutes(1)))
struct TextDisplayTests {
    @Test func monochromeWireTextPaintsBackgroundThenGlyphs() async throws {
        let result = try await replay(flags: 1)
        #expect(result.errors == 0)
        #expect([7,9,14].allSatisfy { result.surface.pixels[$0] == 0xFFFF0000 })
        #expect([8,13,15].allSatisfy { result.surface.pixels[$0] == 0xFF0000FF })
        #expect(result.surface[0,0] == 0xFF000000)
    }

    @Test func antialiasedWireTextBlendsOverBackground() async throws {
        let result = try await replay(flags: 2)
        #expect(result.errors == 0)
        #expect(result.surface[1,1] == 0xFFA0005F)
        #expect(result.surface[1,2] == 0xFF4000BF)
        #expect(result.surface[2,1] == 0xFF0000FF)
    }

    @Test func a8TopDownWireTextUsesByteCoverage() async throws {
        let result = try await replay(flags: 12)
        #expect(result.errors == 0)
        #expect(result.surface[1,1] == 0xFF0000FF)
        #expect(result.surface[2,1] == 0xFF4000BF)
        #expect(result.surface[3,1] == 0xFFFF0000)
        #expect(result.surface[1,2] == 0xFFFF0000)
        #expect(result.surface[2,2] == 0xFF80007F)
        #expect(result.surface[3,2] == 0xFF0000FF)
    }

    @Test func topDownWireTextUsesTheDeclaredRowOrder() async throws {
        let result = try await replay(flags: 9)
        #expect(result.errors == 0)
        #expect([8,13,15].allSatisfy { result.surface.pixels[$0] == 0xFFFF0000 })
        #expect([7,9,14].allSatisfy { result.surface.pixels[$0] == 0xFF0000FF })
    }

    private func replay(flags: UInt8) async throws -> (surface: PixelBuffer,errors: Int) {
        let (client,server) = await MemoryByteStream.pair()
        let connection = ChannelConnection(type: .display,id: 0,stream: client,serverCaps: CapabilitySet())
        let (events,sink) = AsyncStream<DisplayEvent>.makeStream()
        let display = DisplayChannel(connection: connection,events: sink)
        let drain = Task { for await _ in events {} }
        let loop = Task { try await display.run() }
        var create = ByteWriter()
        create.writeU32(0); create.writeU32(6); create.writeU32(5)
        create.writeU32(SurfaceFormat.xRGB32.rawValue); create.writeU32(1)
        var writer = ByteWriter(); writer.writeU32(0)
        for value: Int32 in [0,0,5,6] { writer.writeI32(value) }
        writer.writeU8(0); writer.writeU32(55)
        for value: Int32 in [1,1,3,4] { writer.writeI32(value) }
        writer.writeU8(1); writer.writeU32(0xFF0000)
        writer.writeU8(1); writer.writeU32(0x0000FF)
        writer.writeU16(Ropd.opPut.rawValue); writer.writeU16(Ropd.opXor.rawValue)
        writer.writeU16(1); writer.writeU8(flags)
        for value: Int32 in [2,2,-1,-1] { writer.writeI32(value) }
        writer.writeU16(3); writer.writeU16(2)
        if flags & 4 != 0 { writer.writeBytes([0,64,255,255,128,0]) }
        else { writer.writeBytes(flags == 2 ? [0x40,0x00,0xA0,0x00] : [0x40,0xA0]) }
        var ping = ByteWriter(); ping.writeU32(1); ping.writeU64(0)
        try await server.send(SpiceMessage(type: DisplayServerMessage.surfaceCreate.rawValue,payload: create.bytes).encode() +
            SpiceMessage(type: DisplayServerMessage.drawText.rawValue,payload: writer.bytes).encode() +
            SpiceMessage(type: BaseServerMessage.ping.rawValue,payload: ping.bytes).encode())
        while true {
            let header = try MiniHeader(decoding: try await server.receive(exactly: MiniHeader.size))
            _ = try await server.receive(exactly: Int(header.size))
            if header.type == BaseClientMessage.pong.rawValue { break }
        }
        let surface = try #require(await display.primarySurface()), errors = await display.decodeErrorCount
        await display.close(); loop.cancel(); drain.cancel(); _ = try? await loop.value
        return (surface,errors)
    }
}
