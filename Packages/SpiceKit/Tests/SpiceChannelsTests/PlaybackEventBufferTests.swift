import Testing
@testable import SpiceChannels
import SpiceWire

@Suite(.timeLimit(.minutes(1)))
struct PlaybackEventBufferTests {
    @Test func controlsKeepTheirWireOrderWithoutAnIntermediateBuffer() async throws {
        let buffer = try makeBuffer(events: 8, controls: 8)
        let expected: [PlaybackEvent] = [.start(channels: 2, frequency: 48_000, time: 42),
                                         .latency(milliseconds: 300), .volume(0.5), .mute(true), .stop]
        for event in expected { #expect(buffer.yield(event)) }
        var iterator = buffer.stream().makeAsyncIterator()
        for event in expected { #expect(await iterator.next() == event) }
        buffer.finish()
        #expect(await iterator.next() == .stop)
        #expect(await iterator.next() == nil)
    }

    @Test func audioPressurePurgesPacketsButKeepsStartStopAndNewStart() async throws {
        let buffer = try makeBuffer(events: 5, controls: 4)
        let first = PlaybackEvent.start(channels: 2, frequency: 48_000, time: 1)
        let next = PlaybackEvent.start(channels: 1, frequency: 44_100, time: 2)
        for event in [first, packet(1), .stop, next, packet(2)] { #expect(buffer.yield(event)) }
        #expect(buffer.yield(packet(3)))
        var iterator = buffer.stream().makeAsyncIterator()
        for event in [first, .stop, next, .discontinuity, packet(3)] {
            #expect(await iterator.next() == event)
        }
        buffer.finish()
    }

    @Test func bytePressureAndRepeatedBurstsCoalesceTheDiscontinuityAfterControls() async throws {
        let buffer = try makeBuffer(events: 5, controls: 4, bytes: 3)
        let start = PlaybackEvent.start(channels: 2, frequency: 48_000, time: 1)
        #expect(buffer.yield(start))
        #expect(buffer.yield(packet(1, bytes: [1,1])))
        #expect(buffer.yield(.latency(milliseconds: 400)))
        #expect(buffer.yield(packet(2, bytes: [2,2]))) // Exceeds byte budget.
        #expect(buffer.yield(.volume(0.5)))
        #expect(buffer.yield(packet(3, bytes: [3,3])))
        var iterator = buffer.stream().makeAsyncIterator()
        for event in [start, .latency(milliseconds: 400), .volume(0.5), .discontinuity, packet(3, bytes: [3,3])] {
            #expect(await iterator.next() == event)
        }
        buffer.finish()
    }

    @Test func controlOrMarkerCapacityExhaustionEndsWithStopInsteadOfLosingAControl() async throws {
        let buffer = try makeBuffer(events: 6, controls: 2)
        #expect(buffer.yield(.latency(milliseconds: 200)))
        #expect(buffer.yield(.volume(0.5)))
        #expect(!buffer.yield(.stop))
        #expect(buffer.failure == .controlLimit)
        var iterator = buffer.stream().makeAsyncIterator()
        #expect(await iterator.next() == .stop)
        #expect(await iterator.next() == nil)
        buffer.finish()
        #expect(buffer.failure == .controlLimit)
        #expect(!buffer.yield(packet(4)))
        let tiny = try makeBuffer(events: 1, controls: 1)
        #expect(tiny.yield(packet(1)))
        #expect(!tiny.yield(packet(2)))
        #expect(tiny.failure == .eventLimit)
        var tinyIterator = tiny.stream().makeAsyncIterator()
        #expect(await tinyIterator.next() == .stop)
        #expect(await tinyIterator.next() == nil)
    }

    @Test func oversizedPacketsFailClosedBeforeDirectDelivery() async throws {
        let buffer = PlaybackEventBuffer()
        let task = Task { () -> PlaybackEvent? in
            var iterator = buffer.stream().makeAsyncIterator()
            return await iterator.next()
        }
        try await waitForConsumer(buffer)
        #expect(!buffer.yield(packet(1, bytes: Array(repeating: 0, count: 64 * 1024 + 1))))
        #expect(buffer.failure == .packetLimit)
        #expect(await task.value == .stop)
        #expect(!buffer.yield(.mute(true)))
    }

    @Test func finishDiscardsQueuedAudioAndProducesOnlyOneTerminalStop() async throws {
        let buffer = PlaybackEventBuffer()
        #expect(buffer.yield(packet(1)))
        #expect(buffer.yield(.mute(true)))
        buffer.finish()
        buffer.finish()
        var iterator = buffer.stream().makeAsyncIterator()
        #expect(await iterator.next() == .stop)
        #expect(await iterator.next() == nil)
        #expect(!buffer.yield(packet(2)))
    }

    @Test func aWaitingConsumerReceivesDirectDeliveryAndFinishWakesIt() async throws {
        let buffer = PlaybackEventBuffer()
        let task = Task { () -> [PlaybackEvent?] in
            var iterator = buffer.stream().makeAsyncIterator()
            let first = await iterator.next()
            let second = await iterator.next()
            let end = await iterator.next()
            return [first, second, end]
        }
        try await waitForConsumer(buffer)
        #expect(buffer.yield(.latency(milliseconds: 123)))
        try await waitForConsumer(buffer)
        buffer.finish()
        #expect(await task.value == [.latency(milliseconds: 123), .stop, nil])
    }

    @Test func cancellationWakesTheSuspendedConsumerAndRejectsLaterOffers() async throws {
        let buffer = PlaybackEventBuffer()
        let task = Task { () -> PlaybackEvent? in
            var iterator = buffer.stream().makeAsyncIterator()
            return await iterator.next()
        }
        try await waitForConsumer(buffer)
        task.cancel()
        #expect(await task.value == nil)
        #expect(buffer.failure == nil)
        buffer.finish()
        #expect(!buffer.yield(.stop))
    }

    @Test func cancellationBeforeRegistrationDoesNotLeaveAContinuationBehind() async {
        for _ in 0..<100 {
            let buffer = PlaybackEventBuffer()
            let task = Task { () -> PlaybackEvent? in
                var iterator = buffer.stream().makeAsyncIterator()
                return await iterator.next()
            }
            task.cancel()
            #expect(await task.value == nil)
            #expect(!buffer.hasWaitingConsumer)
            #expect(!buffer.yield(packet(1)))
        }
    }

    @Test func concurrentFinishAndCancelResumeEachWaiterAtMostOnce() async throws {
        for _ in 0..<100 {
            let buffer = PlaybackEventBuffer()
            let task = Task { () -> PlaybackEvent? in
                var iterator = buffer.stream().makeAsyncIterator()
                return await iterator.next()
            }
            try await waitForConsumer(buffer)
            async let closing: Void = Task.detached { buffer.finish() }.value
            task.cancel()
            await closing
            let event = await task.value
            #expect(event == nil || event == .stop)
            #expect(!buffer.hasWaitingConsumer)
            #expect(!buffer.yield(.mute(true)))
        }
    }

    @Test func onlyTheFirstStreamClaimCanConsumeEvents() async {
        let buffer = PlaybackEventBuffer()
        var first = buffer.stream().makeAsyncIterator()
        var second = buffer.stream().makeAsyncIterator()
        #expect(await second.next() == nil)
        #expect(buffer.yield(.mute(true)))
        #expect(await first.next() == .mute(true))
        buffer.finish()
        #expect(await first.next() == .stop)
        #expect(await first.next() == nil)
    }

    @Test func invalidBoundsRejectBeforeAllocatingQueueStorage() {
        for value in [Int.min, 0, 501, Int.max] {
            #expect(PlaybackEventBuffer(maxEvents: value, maxControls: 1, maxAudioBytes: 1) == nil)
        }
        #expect(PlaybackEventBuffer(maxEvents: 2, maxControls: 3, maxAudioBytes: 1) == nil)
        #expect(PlaybackEventBuffer(maxEvents: 2, maxControls: 1, maxAudioBytes: Int.max) == nil)
    }

    private func makeBuffer(events: Int, controls: Int, bytes: Int = 100) throws -> PlaybackEventBuffer {
        try #require(PlaybackEventBuffer(maxEvents: events, maxControls: controls, maxAudioBytes: bytes))
    }

    private func packet(_ time: UInt32, bytes: [UInt8] = [1]) -> PlaybackEvent {
        .data(mode: .raw, time: time, bytes: bytes)
    }

    private func waitForConsumer(_ buffer: PlaybackEventBuffer) async throws {
        for _ in 0..<10_000 {
            if buffer.hasWaitingConsumer { return }
            await Task.yield()
        }
        buffer.finish()
        throw WaitError.consumerDidNotSuspend
    }

    private enum WaitError: Error { case consumerDidNotSuspend }
}
