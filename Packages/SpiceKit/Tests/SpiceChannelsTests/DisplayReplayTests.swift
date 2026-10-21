import Foundation
import Testing
@testable import SpiceChannels
import SpiceCodecs
import SpiceTransport
import SpiceWire

/// Replays display streams captured from a real spice-server (Fixtures/display) through
/// `DisplayChannel` and compares the resulting screens. LZ is the verified baseline; LZ4
/// and GLZ (with its cross-image dictionary) must produce identical pixels.
@Suite("Display replay (real server captures)", .timeLimit(.minutes(1)))
struct DisplayReplayTests {
    static func fixture(_ name: String) throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/display/\(name)")
        return Array(try Data(contentsOf: url))
    }

    /// Feeds a capture to a display channel; returns the final primary surface.
    static func replay(_ name: String) async throws -> (PixelBuffer, errors: Int) {
        let (client, server) = await MemoryByteStream.pair()
        let connection = ChannelConnection(type: .display, id: 0, stream: client,
                                           serverCaps: CapabilitySet(bits: [DisplayCapability.prefCompression.rawValue]))
        let (events, sink) = AsyncStream<DisplayEvent>.makeStream()
        let display = DisplayChannel(connection: connection, events: sink)
        let drain = Task { for await _ in events {} }
        let loop = Task { try await display.run() }
        // The capture, then a PING: once the client's PONG arrives every message before it
        // has been handled (the channel processes messages in order).
        var ping = ByteWriter(); ping.writeU32(0xC0DE); ping.writeU64(0)
        try await server.send(try fixture(name) + SpiceMessage(type: BaseServerMessage.ping.rawValue, payload: ping.bytes).encode())
        while true {
            let header = try MiniHeader(decoding: try await server.receive(exactly: 6))
            let payload = try await server.receive(exactly: Int(header.size))
            if header.type == BaseClientMessage.pong.rawValue, payload.prefix(4) == [0xDE, 0xC0, 0, 0] { break }
        }
        loop.cancel()
        await server.close()
        _ = try? await loop.value
        drain.cancel()
        let surface = try #require(await display.primarySurface())
        return (surface, await display.decodeErrorCount)
    }

    @Test(arguments: ["lz4.bin", "glz.bin", "auto-glz.bin"])
    func matchesTheLZBaseline(_ name: String) async throws {
        let (baseline, baselineErrors) = try await Self.replay("lz.bin")
        #expect(baselineErrors == 0)
        #expect(baseline.width > 0 && baseline.height > 0)
        #expect(Set(baseline.pixels).count > 16, "the capture must contain real content")
        let (screen, errors) = try await Self.replay(name)
        #expect(errors == 0, "decode errors in \(name)")
        #expect(screen.width == baseline.width && screen.height == baseline.height)
        let differing = zip(screen.pixels, baseline.pixels).filter { ($0 & 0x00FF_FFFF) != ($1 & 0x00FF_FFFF) }.count
        #expect(differing == 0, "\(differing) pixels differ in \(name)")
    }
}

@Suite("Stream reports")
struct StreamReportTests {
    @Test func encodesTheWireLayout() {
        let message = DisplayClientEncoder.streamReport(StreamReport(
            streamID: 1, uniqueID: 2, startFrameMMTime: 3, endFrameMMTime: 4, frames: 5, drops: 6, lastFrameDelay: -7))
        #expect(message.type == DisplayClientMessage.streamReport.rawValue)
        #expect(message.payload.count == 32)
        #expect(Array(message.payload[24..<28]) == [0xF9, 0xFF, 0xFF, 0xFF])  // -7
        #expect(Array(message.payload[28..<32]) == [0xFF, 0xFF, 0xFF, 0xFF])  // no audio
    }

    @Test func clockAdvancesFromTheLastSync() async throws {
        let clock = MultimediaClock()
        #expect(clock.now == nil)
        let start = ContinuousClock.now
        clock.set(1000)
        try await Task.sleep(for: .milliseconds(50))
        let now = try #require(clock.now)
        // Busy CI machines can oversleep a lot: bound by the time that really passed.
        let elapsed = ContinuousClock.now - start
        let elapsedMs = UInt32(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        #expect(now >= 1050)
        #expect(now <= 1000 + elapsedMs + 1)
    }
}
