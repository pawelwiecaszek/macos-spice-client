import Foundation
import Testing
@testable import SpiceChannels
import SpiceTransport
import SpiceWire

@Suite(.timeLimit(.minutes(1)))
struct DisplayCacheOwnershipTests {
    @Test func independentDisplaysAdvertiseDistinctExactCacheAndDictionaryIDs() async throws {
        var cacheIDs: [UInt8] = []
        var dictionaryIDs: [UInt8] = []
        for id: UInt8 in [0, 1, 255] {
            let (client, server) = await MemoryByteStream.pair()
            let connection = ChannelConnection(type: .display, id: id, stream: client, serverCaps: CapabilitySet())
            let (_, sink) = AsyncStream<DisplayEvent>.makeStream()
            let display = DisplayChannel(connection: connection, events: sink)
            let loop = Task { try await display.run() }
            let header = try MiniHeader(decoding: try await server.receive(exactly: 6))
            #expect(header.type == DisplayClientMessage.initialize.rawValue)
            var reader = ByteReader(try await server.receive(exactly: Int(header.size)))
            let cacheID = try reader.readU8()
            _ = try reader.readU64()
            let dictionaryID = try reader.readU8()
            #expect(cacheID == id)
            #expect(dictionaryID == id)
            cacheIDs.append(cacheID); dictionaryIDs.append(dictionaryID)
            await connection.close()
            loop.cancel()
            _ = try? await loop.value
        }
        #expect(Set(cacheIDs).count == 3)
        #expect(Set(dictionaryIDs).count == 3)
    }
    @Test func invalidationKeepsCacheUntilEmbeddedBarrierCompletes() async throws {
        let sync = ChannelSynchronization()
        let (client, server) = await MemoryByteStream.pair()
        let (peerClient, peerServer) = await MemoryByteStream.pair()
        let connection = ChannelConnection(type: .display, id: 0, stream: client, serverCaps: CapabilitySet(), synchronization: sync)
        let peer = ChannelConnection(type: .cursor, id: 0, stream: peerClient, serverCaps: CapabilitySet(), synchronization: sync)
        try await connection.prepare(); try await peer.prepare()
        try await sync.expect([.init(type: .display, id: 0), .init(type: .cursor, id: 0)])
        let (_, sink) = AsyncStream<DisplayEvent>.makeStream()
        let display = DisplayChannel(connection: connection, events: sink)
        let loop = Task { try await display.run() }
        let channel = ServerChannel(stream: server, type: .display)
        _ = try await channel.expect(DisplayClientMessage.initialize.rawValue)
        var surface = ByteWriter()
        for value: UInt32 in [0, 1, 1, SurfaceFormat.xRGB32.rawValue, 1] { surface.writeU32(value) }
        try await channel.send(DisplayServerMessage.surfaceCreate.rawValue, surface.bytes)
        try await channel.send(DisplayServerMessage.drawCopy.rawValue, Self.copyOfCachedQUIC())
        try await Self.ping(channel)
        #expect(await display.cachedPixmapCount == 1)
        try await peerServer.send(SpiceMessage(type: 101, payload: []).encode())
        _ = try await peer.nextMessage()
        try await channel.send(DisplayServerMessage.invalAllPixmaps.rawValue,
            ChannelOrderingIntegrationTests.waitPayload(type: .cursor, id: 0, serial: 1))
        await ChannelOrderingIntegrationTests.awaitWaiter(sync)
        #expect(await display.cachedPixmapCount == 1, "cache references remain valid while another handler is using them")
        await peer.messageHandled()
        try await Self.ping(channel)
        #expect(await display.cachedPixmapCount == 0)
        await connection.close(); await peer.close()
        loop.cancel(); _ = try? await loop.value
    }

    @Test func independentResolverCacheCannotReadOrInvalidateAnotherDisplay() throws {
        var first = ImageResolver(pixmapCacheBudget: 16)
        var second = ImageResolver(pixmapCacheBudget: 16)
        let source = try Self.quicImage(cached: false)
        let reference = try Self.quicImage(cached: true)
        let pixels = try first.resolve(source, surface: { _ in nil })
        #expect(try first.resolve(reference, surface: { _ in nil }).pixels == pixels.pixels)
        #expect(throws: ImageResolveError.cacheMiss(0xCAFE)) { try second.resolve(reference, surface: { _ in nil }) }
        _ = try second.resolve(source, surface: { _ in nil })
        first.invalidateAllPixmaps()
        #expect(try second.resolve(reference, surface: { _ in nil }).pixels == pixels.pixels)
        #expect(throws: ImageResolveError.cacheMiss(0xCAFE)) { try first.resolve(reference, surface: { _ in nil }) }
    }

    @Test func realGLZHistoryDoesNotLeakBetweenResolvers() throws {
        var crossImageReferences = 0
        for name in ["glz.bin", "auto-glz.bin"] {
            var history = ImageResolver(pixmapCacheBudget: DisplayChannel.pixmapCacheBudget)
            var reader = ByteReader(try DisplayReplayTests.fixture(name))
            while reader.remaining > 0 {
                let type = try reader.readU16(), size = try reader.readU32()
                let payload = Array(try reader.readBytes(Int(size)))
                guard type == DisplayServerMessage.drawCopy.rawValue,
                      let image = try DrawCopy(decoding: payload).source else { continue }
                switch image.payload {
                case .glzRGB, .zlibGLZRGB: break
                default: continue
                }
                _ = try history.resolve(image, surface: { _ in nil })
                var otherDisplay = ImageResolver(pixmapCacheBudget: DisplayChannel.pixmapCacheBudget)
                do { _ = try otherDisplay.resolve(image, surface: { _ in nil }) }
                catch { crossImageReferences += 1 }
            }
        }
        #expect(crossImageReferences > 0, "the real replay must exercise dictionary history rather than literal-only images")
    }

    private static func ping(_ channel: ServerChannel) async throws {
        var ping = ByteWriter(); ping.writeU32(17); ping.writeU64(0)
        try await channel.send(BaseServerMessage.ping.rawValue, ping.bytes)
        _ = try await channel.expect(BaseClientMessage.pong.rawValue)
    }

    private static func quicBytes() throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/codecs/quic-rgb32-1x1.bin")
        return Array(try Data(contentsOf: url))
    }

    private static func quicImage(cached: Bool) throws -> Image {
        var w = ByteWriter(); w.writeU8(0)
        w.writeU64(0xCAFE); w.writeU8(cached ? ImageType.fromCache.rawValue : ImageType.quic.rawValue)
        w.writeU8(cached ? 0 : ImageFlags.cacheMe.rawValue); w.writeU32(1); w.writeU32(1)
        if !cached { let bytes = try quicBytes(); w.writeU32(UInt32(bytes.count)); w.writeBytes(bytes) }
        return try #require(try Image.decode(at: 1, in: ByteReader(w.bytes)))
    }

    private static func copyOfCachedQUIC() throws -> [UInt8] {
        var w = ByteWriter()
        w.writeU32(0); for value: Int32 in [0, 0, 1, 1] { w.writeI32(value) }; w.writeU8(0)
        let pointer = w.count; w.writeU32(0)
        for value: Int32 in [0, 0, 1, 1] { w.writeI32(value) }
        w.writeU16(Ropd.opPut.rawValue); w.writeU8(ScaleMode.nearest.rawValue)
        w.writeU8(0); w.writeI32(0); w.writeI32(0); w.writeU32(0)
        let imageAt = UInt32(w.count)
        w.writeU64(0xCAFE); w.writeU8(ImageType.quic.rawValue); w.writeU8(ImageFlags.cacheMe.rawValue)
        w.writeU32(1); w.writeU32(1)
        let quic = try quicBytes(); w.writeU32(UInt32(quic.count)); w.writeBytes(quic)
        var bytes = w.bytes
        for index in 0..<4 { bytes[pointer + index] = UInt8(truncatingIfNeeded: imageAt >> (index * 8)) }
        return bytes
    }

}
