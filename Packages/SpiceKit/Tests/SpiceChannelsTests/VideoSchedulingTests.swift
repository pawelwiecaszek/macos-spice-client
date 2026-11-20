import Foundation
import Synchronization
import Testing
@testable import SpiceChannels
import SpiceCodecs
import SpiceTransport
import SpiceWire
#if canImport(ImageIO)
import ImageIO
import CoreGraphics

@Suite(.timeLimit(.minutes(1)))
struct VideoSchedulingTests {
    @Test func dueFramesAcrossStreamsCommitChronologicallyOnOneSurface() async throws {
        let time = ManualTime(), clock = MultimediaClock(now: { time.now })
        clock.set(100)
        let fixture = try await makeFixture(clock: clock)
        let red = try redJPEG(), green = try redJPEG(green: true)
        try await fixture.server.send(streamCreate(streamID: 2).encode() + data(red, time: 200).encode()
            + data(green, time: 190, streamID: 2).encode())
        _ = try await fixture.barrier()
        time.advance(.milliseconds(100))
        try await fixture.display.processVideoDeadlines()
        let expected = try JPEGDecoder.decode(red[...])[0,0]
        #expect(await fixture.display.primarySurface()?[0,0] == expected)
        await fixture.close()
    }

    @Test func futureFrameDoesNotBlockMessagesAndUsesTheLatestClipAtDeadline() async throws {
        let time = ManualTime(), clock = MultimediaClock(now: { time.now })
        clock.set(100)
        let fixture = try await makeFixture(clock: clock)
        let jpeg = try redJPEG()
        try await fixture.server.send(data(jpeg, time: 200).encode())
        _ = try await fixture.barrier()
        #expect(await fixture.display.pendingVideoPixels == 4)
        #expect(await fixture.display.primarySurface()?.pixels.allSatisfy { $0 == 0xFF000000 } == true)
        var clip = ByteWriter(); clip.writeU32(1); clip.writeU8(1); clip.writeU32(1)
        for value: Int32 in [0,0,2,1] { clip.writeI32(value) }
        try await fixture.server.send(SpiceMessage(type: DisplayServerMessage.streamClip.rawValue, payload: clip.bytes).encode())
        _ = try await fixture.barrier()
        time.advance(.milliseconds(100))
        try await fixture.display.processVideoDeadlines()
        let surface = try #require(await fixture.display.primarySurface())
        #expect(surface[0,0] != 0xFF000000 && surface[1,0] == 0xFF000000)
        #expect(surface[0,1] != 0xFF000000 && surface[1,1] == 0xFF000000)
        #expect(await fixture.display.pendingVideoPixels == 0)
        await fixture.close()
    }

    @Test func surfaceReplacementAndStreamReuseDiscardPendingFrames() async throws {
        let time = ManualTime(), clock = MultimediaClock(now: { time.now })
        clock.set(100)
        let fixture = try await makeFixture(clock: clock)
        try await fixture.server.send(data(try redJPEG(), time: 200).encode())
        _ = try await fixture.barrier()
        #expect(await fixture.display.pendingVideoPixels == 4)
        try await fixture.server.send(surfaceCreate().encode() + streamCreate().encode())
        _ = try await fixture.barrier()
        #expect(await fixture.display.pendingVideoPixels == 0)
        time.advance(.milliseconds(100))
        try await fixture.display.processVideoDeadlines()
        #expect(await fixture.display.primarySurface()?.pixels.allSatisfy { $0 == 0xFF000000 } == true)
        await fixture.close()
    }

    @Test func closeCancelsFutureFramesAndUnknownClockFallsBackToImmediate() async throws {
        let time = ManualTime(), clock = MultimediaClock(now: { time.now })
        clock.set(100)
        let fixture = try await makeFixture(clock: clock)
        try await fixture.server.send(data(try redJPEG(), time: 200).encode())
        _ = try await fixture.barrier()
        await fixture.display.close()
        time.advance(.milliseconds(100))
        try await fixture.display.processVideoDeadlines()
        #expect(await fixture.display.pendingVideoPixels == 0)
        #expect(await fixture.display.primarySurface()?.pixels.allSatisfy { $0 == 0xFF000000 } == true)
        await fixture.close()
        let unknown = try await makeFixture(clock: nil)
        try await unknown.server.send(data(try redJPEG(), time: .max).encode())
        _ = try await unknown.barrier()
        #expect(await unknown.display.primarySurface()?[0,0] != 0xFF000000)
        #expect(await unknown.display.pendingVideoPixels == 0)
        await unknown.close()
    }

    @Test func oldFramesNeverPaintBackwardsAndReportsUseFreshAudioDelay() async throws {
        let time = ManualTime(), clock = MultimediaClock(now: { time.now })
        clock.set(100)
        let epoch = clock.beginAudio()
        #expect(clock.updateAudio(time: 100, epoch: epoch, at: time.now, delayMilliseconds: 70))
        let fixture = try await makeFixture(clock: clock)
        var activate = ByteWriter()
        for value: UInt32 in [1,7,1,1000] { activate.writeU32(value) }
        try await fixture.server.send(SpiceMessage(type: DisplayServerMessage.streamActivateReport.rawValue, payload: activate.bytes).encode()
            + data(try redJPEG(), time: 100).encode())
        let responses = try await fixture.barrier()
        let report = try #require(responses.first { $0.type == DisplayClientMessage.streamReport.rawValue })
        var reader = ByteReader(report.payload)
        _ = try reader.readBytes(16)
        #expect(try reader.readU32() == 1)
        #expect(try reader.readU32() == 0)
        #expect(try reader.readI32() == 0)
        #expect(try reader.readU32() == 70)
        let before = try #require(await fixture.display.primarySurface())
        try await fixture.server.send(data(try redJPEG(green: true), time: 90).encode())
        let oldResponses = try await fixture.barrier()
        #expect(await fixture.display.primarySurface() == before)
        let late = try #require(oldResponses.first { $0.type == DisplayClientMessage.streamReport.rawValue })
        var lateReader = ByteReader(late.payload); _ = try lateReader.readBytes(20)
        #expect(try lateReader.readU32() == 1)
        await fixture.close()
    }

    @Test func waitingForAH264KeyframeIsNotAnUnsupportedCodecReport() async throws {
        let clock = MultimediaClock(); clock.set(100)
        let fixture = try await makeFixture(clock: clock, codec: .h264)
        var activate = ByteWriter()
        for value: UInt32 in [1,7,1,1000] { activate.writeU32(value) }
        try await fixture.server.send(SpiceMessage(type: DisplayServerMessage.streamActivateReport.rawValue, payload: activate.bytes).encode()
            + data([0,0,0,1,9,0], time: 100).encode())
        let responses = try await fixture.barrier()
        #expect(!responses.contains { $0.type == DisplayClientMessage.streamReport.rawValue })
        #expect(await fixture.display.pendingVideoPixels == 0)
        await fixture.close()
    }

    private func makeFixture(clock: MultimediaClock?, codec: VideoCodecType = .mjpeg) async throws -> Fixture {
        let (client,server) = await MemoryByteStream.pair()
        let connection = ChannelConnection(type: .display, id: 0, stream: client, serverCaps: CapabilitySet())
        let (events,sink) = AsyncStream<DisplayEvent>.makeStream()
        let display = DisplayChannel(connection: connection, events: sink, clock: clock)
        let fixture = Fixture(display: display, server: server,
                              loop: Task { try await display.run() }, drain: Task { for await _ in events {} })
        try await server.send(surfaceCreate().encode() + streamCreate(codec: codec).encode())
        _ = try await fixture.barrier()
        return fixture
    }

    private func surfaceCreate() -> SpiceMessage {
        var writer = ByteWriter()
        for value: UInt32 in [0,2,2,SurfaceFormat.xRGB32.rawValue,1] { writer.writeU32(value) }
        return .init(type: DisplayServerMessage.surfaceCreate.rawValue, payload: writer.bytes)
    }
    private func streamCreate(codec: VideoCodecType = .mjpeg, streamID: UInt32 = 1) -> SpiceMessage {
        var writer = ByteWriter(); writer.writeU32(0); writer.writeU32(streamID)
        writer.writeU8(1); writer.writeU8(codec.rawValue); writer.writeU64(0)
        for _ in 0..<4 { writer.writeU32(2) }
        for value: Int32 in [0,0,2,2] { writer.writeI32(value) }
        writer.writeU8(0)
        return .init(type: DisplayServerMessage.streamCreate.rawValue, payload: writer.bytes)
    }
    private func data(_ bytes: [UInt8], time: UInt32, streamID: UInt32 = 1) -> SpiceMessage {
        var writer = ByteWriter(); writer.writeU32(streamID); writer.writeU32(time); writer.writeU32(UInt32(bytes.count)); writer.writeBytes(bytes)
        return .init(type: DisplayServerMessage.streamData.rawValue, payload: writer.bytes)
    }
    private func redJPEG(green: Bool = false) throws -> [UInt8] {
        let pixels = Data(Array(repeating: [UInt8(green ? 0 : 255),green ? 255 : 0,0,255], count: 4).flatMap { $0 })
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return Array(output as Data)
    }
    private final class ManualTime: Sendable {
        private let value = Mutex(ContinuousClock.now)
        var now: ContinuousClock.Instant { value.withLock { $0 } }
        func advance(_ duration: Duration) { value.withLock { $0 = $0.advanced(by: duration) } }
    }
    private struct Fixture {
        let display: DisplayChannel
        let server: MemoryByteStream
        let loop: Task<Void, any Error>
        let drain: Task<Void, Never>
        func barrier() async throws -> [SpiceMessage] {
            var ping = ByteWriter(); ping.writeU32(123); ping.writeU64(0)
            try await server.send(SpiceMessage(type: BaseServerMessage.ping.rawValue, payload: ping.bytes).encode())
            var messages: [SpiceMessage] = []
            while true {
                let header = try MiniHeader(decoding: try await server.receive(exactly: MiniHeader.size))
                let message = SpiceMessage(type: header.type, payload: try await server.receive(exactly: Int(header.size)))
                if message.type == BaseClientMessage.pong.rawValue { return messages }
                messages.append(message)
            }
        }
        func close() async {
            await display.close(); loop.cancel(); drain.cancel(); await server.close(); _ = try? await loop.value
        }
    }
}
#endif
