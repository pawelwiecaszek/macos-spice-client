import Testing
@testable import SpiceChannels
import SpiceCodecs
import SpiceTransport
import SpiceWire

@Suite(.timeLimit(.minutes(1)))
struct Rop3DisplayTests {
    @Test func ternaryDrawProducesPixelsInsteadOfBeingSkipped() async throws {
        let (pixels, errors) = try await replay([
            surface(0), surface(1), fill(0, color: 0x0000_00FF), fill(1, color: 0x00FF_0000),
            rop(source: 1, code: 0x66)
        ])
        #expect(errors == 0)
        #expect(pixels.pixels == [0xFFFF_00FF, 0xFFFF_00FF, 0xFFFF_00FF])
    }

    @Test func patternSurfaceIsResolvedBeforeDrawing() async throws {
        let (pixels, errors) = try await replay([
            surface(0), surface(1), surface(2), fill(0, color: 0x0000_00FF),
            fill(1, color: 0x00FF_0000), fill(2, color: 0x0000_FF00),
            rop(source: 1, brushSurface: 2, code: 0xF0)
        ])
        #expect(errors == 0)
        #expect(pixels.pixels == [0xFF00_FF00, 0xFF00_FF00, 0xFF00_FF00])
    }

    @Test func unsupportedMaskIsNotSilentlyRemoved() async throws {
        let (pixels, errors) = try await replay([
            surface(0), surface(1), fill(0, color: 0x0000_00FF), fill(1, color: 0x00FF_0000),
            rop(source: 1, code: 0xCC, maskImage: image(surface: 1))
        ])
        #expect(errors == 1)
        #expect(pixels.pixels == [0xFF00_00FF, 0xFF00_00FF, 0xFF00_00FF])
    }

    @Test func bitmapMaskLimitsTheTernaryDraw() async throws {
        var mask = ByteWriter()
        mask.writeU64(8); mask.writeU8(ImageType.bitmap.rawValue); mask.writeU8(0)
        mask.writeU32(3); mask.writeU32(1)
        mask.writeU8(BitmapFormat.oneBitBE.rawValue); mask.writeU8(BitmapFlags.topDown.rawValue)
        mask.writeU32(3); mask.writeU32(1); mask.writeU32(1); mask.writeU32(0)
        mask.writeU8(0xA0) // first and third pixels only
        let (pixels, errors) = try await replay([
            surface(0), surface(1), fill(0, color: 0x0000_00FF), fill(1, color: 0x00FF_0000),
            rop(source: 1, code: 0xCC, maskImage: mask.bytes)
        ])
        #expect(errors == 0)
        #expect(pixels.pixels == [0xFFFF_0000, 0xFF00_00FF, 0xFFFF_0000])
    }

    @Test func sourceSurfaceAliasesUseThePreDrawSnapshot() async throws {
        let (pixels, errors) = try await replay([
            surface(0), fill(0, color: 1), fill(0, color: 2, x: 1, width: 1), fill(0, color: 4, x: 2, width: 1),
            rop(source: 0, code: 0xCC, box: Rect(x: 1, y: 0, width: 2, height: 1),
                sourceArea: Rect(x: 0, y: 0, width: 2, height: 1))
        ])
        #expect(errors == 0)
        #expect(pixels.pixels == [0xFF00_0001, 0xFF00_0001, 0xFF00_0002])
    }

    @Test func patternSurfaceAliasesUseThePreDrawSnapshot() async throws {
        let (pixels, errors) = try await replay([
            surface(0), surface(1), fill(0, color: 1), fill(0, color: 2, x: 1, width: 1), fill(0, color: 4, x: 2, width: 1),
            rop(source: 1, brushSurface: 0, code: 0xF0, box: Rect(x: 1, y: 0, width: 2, height: 1),
                sourceArea: Rect(x: 0, y: 0, width: 2, height: 1), patternOriginX: 1)
        ])
        #expect(errors == 0)
        #expect(pixels.pixels == [0xFF00_0001, 0xFF00_0001, 0xFF00_0002])
    }

    @Test func excessiveClipWorkClosesTheChannelBeforePainting() async throws {
        let (client, server) = await MemoryByteStream.pair()
        let connection = ChannelConnection(type: .display, id: 0, stream: client, serverCaps: CapabilitySet())
        let (_, sink) = AsyncStream<DisplayEvent>.makeStream()
        let display = DisplayChannel(connection: connection, events: sink)
        var clip = ByteWriter(); clip.writeU8(1); clip.writeU32(9)
        for _ in 0..<9 { rect(&clip) }
        var payload = rop(source: 1, code: 0xCC).payload
        let delta = clip.bytes.count - 1
        payload.replaceSubrange(20..<21, with: clip.bytes)
        var pointer = ByteWriter(); pointer.writeU32(UInt32(61 + delta))
        payload.replaceSubrange((21 + delta)..<(25 + delta), with: pointer.bytes)
        try await server.send(surface(0).encode() + surface(1).encode() +
            SpiceMessage(type: DisplayServerMessage.drawRop3.rawValue, payload: payload).encode())
        await #expect(throws: WireError.limitExceeded("ROP3 clip work budget")) { try await display.run() }
        #expect(await display.primarySurface()?.pixels == [0xFF00_0000, 0xFF00_0000, 0xFF00_0000])
        await display.close()
    }

    private func replay(_ messages: [SpiceMessage]) async throws -> (PixelBuffer, Int) {
        let (client, server) = await MemoryByteStream.pair()
        let connection = ChannelConnection(type: .display, id: 0, stream: client, serverCaps: CapabilitySet())
        let (events, sink) = AsyncStream<DisplayEvent>.makeStream()
        let display = DisplayChannel(connection: connection, events: sink)
        let drain = Task { for await _ in events {} }
        let loop = Task { try await display.run() }
        var ping = ByteWriter(); ping.writeU32(0xC1); ping.writeU64(0)
        try await server.send(messages.flatMap { $0.encode() } + SpiceMessage(type: BaseServerMessage.ping.rawValue, payload: ping.bytes).encode())
        while true {
            let header = try MiniHeader(decoding: try await server.receive(exactly: MiniHeader.size))
            _ = try await server.receive(exactly: Int(header.size))
            if header.type == BaseClientMessage.pong.rawValue { break }
        }
        let pixels = try #require(await display.primarySurface())
        let errors = await display.decodeErrorCount
        await display.close(); loop.cancel(); drain.cancel()
        _ = try? await loop.value
        return (pixels, errors)
    }

    private func surface(_ id: UInt32) -> SpiceMessage {
        var writer = ByteWriter()
        writer.writeU32(id); writer.writeU32(3); writer.writeU32(1)
        writer.writeU32(SurfaceFormat.xRGB32.rawValue); writer.writeU32(id == 0 ? 1 : 0)
        return SpiceMessage(type: DisplayServerMessage.surfaceCreate.rawValue, payload: writer.bytes)
    }

    private func base(_ writer: inout ByteWriter, surface: UInt32 = 0) {
        writer.writeU32(surface)
        rect(&writer)
        writer.writeU8(0)
    }

    private func rect(_ writer: inout ByteWriter, value: Rect = Rect(x: 0, y: 0, width: 3, height: 1)) {
        writer.writeI32(value.top); writer.writeI32(value.left); writer.writeI32(value.bottom); writer.writeI32(value.right)
    }

    private func fill(_ id: UInt32, color: UInt32, x: Int = 0, width: Int = 3) -> SpiceMessage {
        var writer = ByteWriter(); writer.writeU32(id)
        rect(&writer, value: Rect(x: x, y: 0, width: width, height: 1)); writer.writeU8(0)
        writer.writeU8(1); writer.writeU32(color); writer.writeU16(Ropd.opPut.rawValue)
        writer.writeU8(0); writer.writeI32(0); writer.writeI32(0); writer.writeU32(0)
        return SpiceMessage(type: DisplayServerMessage.drawFill.rawValue, payload: writer.bytes)
    }

    private func image(surface: UInt32) -> [UInt8] {
        var writer = ByteWriter()
        writer.writeU64(0); writer.writeU8(ImageType.surface.rawValue); writer.writeU8(0)
        writer.writeU32(3); writer.writeU32(1); writer.writeU32(surface)
        return writer.bytes
    }

    private func rop(source: UInt32, brushSurface: UInt32? = nil, code: UInt8, maskImage: [UInt8] = [],
                     box: Rect = Rect(x: 0, y: 0, width: 3, height: 1),
                     sourceArea: Rect = Rect(x: 0, y: 0, width: 3, height: 1), patternOriginX: Int32 = 0) -> SpiceMessage {
        var writer = ByteWriter(); writer.writeU32(0); rect(&writer, value: box); writer.writeU8(0)
        writer.writeU32(0); rect(&writer, value: sourceArea)
        if brushSurface != nil {
            writer.writeU8(2); writer.writeU32(0); writer.writeI32(patternOriginX); writer.writeI32(0)
        } else { writer.writeU8(1); writer.writeU32(0x0000_FF00) }
        writer.writeU8(code); writer.writeU8(ScaleMode.nearest.rawValue)
        writer.writeU8(0); writer.writeI32(0); writer.writeI32(0); writer.writeU32(0)
        var bytes = writer.bytes
        let maskPointer = bytes.count - 4
        func patch(_ offset: Int, value: Int) {
            var pointer = ByteWriter(); pointer.writeU32(UInt32(value))
            bytes.replaceSubrange(offset..<(offset + 4), with: pointer.bytes)
        }
        patch(21, value: bytes.count); bytes += image(surface: source)
        if let brushSurface { patch(42, value: bytes.count); bytes += image(surface: brushSurface) }
        if !maskImage.isEmpty { patch(maskPointer, value: bytes.count); bytes += maskImage }
        return SpiceMessage(type: DisplayServerMessage.drawRop3.rawValue, payload: bytes)
    }
}
