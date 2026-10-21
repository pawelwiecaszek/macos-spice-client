import Testing
@testable import SpiceChannels
import SpiceTransport
import SpiceWire

@Suite("Audio channels", .timeLimit(.minutes(1)))
struct AudioChannelTests {
    private func pair(_ type: ChannelType) async -> (ChannelConnection, ServerChannel) {
        let (client, server) = await MemoryByteStream.pair()
        return (ChannelConnection(type: type, id: 0, stream: client, serverCaps: CapabilitySet(bits: [])),
                ServerChannel(stream: server))
    }

    @Test func playbackStartModeDataVolume() async throws {
        let (connection, server) = await pair(.playback)
        let (events, sink) = AsyncStream<PlaybackEvent>.makeStream()
        let channel = PlaybackChannel(connection: connection, events: sink)
        let loop = Task { try await channel.run() }
        var it = events.makeAsyncIterator()

        var start = ByteWriter()
        start.writeU32(2); start.writeU16(1); start.writeU32(48_000); start.writeU32(1234)
        try await server.send(PlaybackServerMessage.start.rawValue, start.bytes)
        #expect(await it.next() == .start(channels: 2, frequency: 48_000))

        var mode = ByteWriter(); mode.writeU32(5); mode.writeU16(AudioDataMode.opus.rawValue)
        try await server.send(PlaybackServerMessage.mode.rawValue, mode.bytes)
        var data = ByteWriter(); data.writeU32(10); data.writeBytes([1, 2, 3])
        try await server.send(PlaybackServerMessage.data.rawValue, data.bytes)
        #expect(await it.next() == .data(mode: .opus, time: 10, bytes: [1, 2, 3]))

        var volume = ByteWriter(); volume.writeU8(2); volume.writeU16(65535); volume.writeU16(0)
        try await server.send(PlaybackServerMessage.volume.rawValue, volume.bytes)
        guard case .volume(let level) = await it.next() else { Issue.record("no volume"); return }
        #expect(abs(level - 0.5) < 0.01)

        // An unsupported sample format is ignored, not passed on.
        var bad = ByteWriter(); bad.writeU32(2); bad.writeU16(7); bad.writeU32(48_000); bad.writeU32(0)
        try await server.send(PlaybackServerMessage.start.rawValue, bad.bytes)
        try await server.send(PlaybackServerMessage.mute.rawValue, [1])
        #expect(await it.next() == .mute(true))
        loop.cancel()
        await channel.close()
    }

    @Test func recordSendsModeAndMarkBeforeData() async throws {
        let (connection, server) = await pair(.record)
        let (events, sink) = AsyncStream<RecordEvent>.makeStream()
        let channel = RecordChannel(connection: connection, events: sink)
        let loop = Task { try await channel.run() }
        var it = events.makeAsyncIterator()

        // Before START nothing is sent.
        await channel.send([1, 2], mode: .raw, time: 1)
        var start = ByteWriter(); start.writeU32(1); start.writeU16(1); start.writeU32(48_000)
        try await server.send(RecordServerMessage.start.rawValue, start.bytes)
        #expect(await it.next() == .start(channels: 1, frequency: 48_000))

        await channel.send([9, 8, 7, 6], mode: .raw, time: 100)
        await channel.send([5, 4], mode: .raw, time: 110)
        let first = try await server.receive()
        #expect(first.type == RecordClientMessage.mode.rawValue)
        #expect(first.payload == [100, 0, 0, 0, 1, 0])
        #expect(try await server.receive().type == RecordClientMessage.startMark.rawValue)
        let data = try await server.receive()
        #expect(data.type == RecordClientMessage.data.rawValue && data.payload == [100, 0, 0, 0, 9, 8, 7, 6])
        #expect(try await server.receive().payload == [110, 0, 0, 0, 5, 4])
        loop.cancel()
        await channel.close()
    }
}
