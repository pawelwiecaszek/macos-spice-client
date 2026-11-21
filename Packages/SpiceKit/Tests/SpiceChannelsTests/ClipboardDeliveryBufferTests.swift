import Testing
@testable import SpiceChannels
import SpiceAgent

@Suite(.timeLimit(.minutes(1)))
struct ClipboardDeliveryBufferTests {
    @Test func controlsAndDataKeepOrderAndConsumedPayloadReleasesBudget() async {
        let (stream, buffer) = ClipboardDeliveryBuffer.makeStream(maximumEvents: 8, maximumBytes: 3)
        let messages: [ClipboardMessage] = [
            .grab(selection: .clipboard, types: [.utf8Text, .png]),
            .request(selection: .clipboard, type: .utf8Text),
            .data(selection: .clipboard, type: .utf8Text, bytes: [1, 2, 3]),
            .release(selection: .clipboard)
        ]
        for message in messages { #expect(buffer.yield(delivery(message))) }
        var iterator = stream.makeAsyncIterator()
        for message in messages { #expect(await iterator.next()?.message == message) }
        let next = packet([4, 5, 6])
        #expect(buffer.yield(next))
        #expect(await iterator.next()?.message == next.message)
        buffer.finish()
        #expect(await iterator.next()?.message == nil)
    }

    @Test func eventPressureEndsInsteadOfDisplacingClipboardControls() async {
        let (stream, buffer) = ClipboardDeliveryBuffer.makeStream(maximumEvents: 2, maximumBytes: 3)
        #expect(buffer.yield(delivery(.grab(selection: .clipboard, types: [.png]))))
        #expect(buffer.yield(delivery(.request(selection: .clipboard, type: .png))))
        #expect(!buffer.yield(packet([1])))
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.message == nil)
        #expect(!buffer.yield(delivery(.release(selection: .clipboard))))
    }

    @Test func aggregatePayloadPressureIsTerminalEvenWithEventCapacity() async {
        let (stream, buffer) = ClipboardDeliveryBuffer.makeStream(maximumEvents: 8, maximumBytes: 3)
        #expect(buffer.yield(packet([1, 2])))
        #expect(buffer.yield(delivery(.release(selection: .clipboard))))
        #expect(!buffer.yield(packet([3, 4])))
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.message == nil)
        #expect(!buffer.yield(packet([])))
    }

    @Test func oversizedPayloadFailsBeforeDirectHandoffAndWakesWaiter() async throws {
        let (stream, buffer) = ClipboardDeliveryBuffer.makeStream(maximumBytes: 2)
        let consumer = Task { () -> ClipboardMessage? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()?.message
        }
        try await waitForConsumer(buffer)
        #expect(!buffer.yield(packet([1, 2, 3])))
        #expect(await consumer.value == nil)
        buffer.finish()
        #expect(!buffer.hasWaitingConsumer)
    }

    @Test func directHandoffDoesNotOccupyTheQueuedPayloadBudget() async throws {
        let (stream, buffer) = ClipboardDeliveryBuffer.makeStream(maximumEvents: 1, maximumBytes: 2)
        let consumer = Task { () -> ClipboardMessage? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()?.message
        }
        try await waitForConsumer(buffer)
        let first = packet([1, 2])
        #expect(buffer.yield(first))
        #expect(await consumer.value == first.message)
        let second = packet([3, 4])
        #expect(buffer.yield(second))
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.message == second.message)
        buffer.finish()
    }

    @Test func finishDiscardsPendingRepliesAndIsIdempotent() async {
        let (stream, buffer) = ClipboardDeliveryBuffer.makeStream()
        #expect(buffer.yield(packet([1])))
        #expect(buffer.yield(delivery(.release(selection: .clipboard))))
        buffer.finish()
        buffer.finish()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.message == nil)
        #expect(await iterator.next()?.message == nil)
        #expect(!buffer.yield(packet([2])))
    }

    @Test func cancellationEndsSuspendedDeliveryAndRejectsLaterEvents() async throws {
        let (stream, buffer) = ClipboardDeliveryBuffer.makeStream()
        let consumer = Task { () -> ClipboardMessage? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()?.message
        }
        try await waitForConsumer(buffer)
        consumer.cancel()
        #expect(await consumer.value == nil)
        #expect(!buffer.hasWaitingConsumer)
        #expect(!buffer.yield(packet([1])))
        buffer.finish()
    }

    @Test func concurrentWaitingConsumersEndBothWithoutDoubleResume() async throws {
        let (stream, buffer) = ClipboardDeliveryBuffer.makeStream()
        let first = Task { () -> ClipboardMessage? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()?.message
        }
        try await waitForConsumer(buffer)
        let second = Task { () -> ClipboardMessage? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()?.message
        }
        #expect(await first.value == nil)
        #expect(await second.value == nil)
        #expect(!buffer.hasWaitingConsumer)
        #expect(!buffer.yield(packet([1])))
    }

    @Test func configuredBoundsClampToFiniteEventAndPayloadLimits() async {
        let (minimumStream, minimum) = ClipboardDeliveryBuffer.makeStream(maximumEvents: .min, maximumBytes: .min)
        #expect(minimum.yield(packet([1])))
        #expect(!minimum.yield(packet([])))
        var minimumIterator = minimumStream.makeAsyncIterator()
        #expect(await minimumIterator.next()?.message == nil)

        let (maximumStream, maximum) = ClipboardDeliveryBuffer.makeStream(maximumEvents: .max, maximumBytes: .max)
        for _ in 0..<64 { #expect(maximum.yield(delivery(.release(selection: .clipboard)))) }
        #expect(!maximum.yield(delivery(.release(selection: .clipboard))))
        var maximumIterator = maximumStream.makeAsyncIterator()
        #expect(await maximumIterator.next()?.message == nil)

        let (byteStream, bytes) = ClipboardDeliveryBuffer.makeStream(maximumBytes: .max)
        #expect(!bytes.yield(packet([UInt8](repeating: 0, count: ClipboardCodec.maxDataSize + 1))))
        var byteIterator = byteStream.makeAsyncIterator()
        #expect(await byteIterator.next()?.message == nil)
    }

    @Test func oversizedControlMetadataAlsoFailsBeforeDirectHandoff() async throws {
        let (stream, buffer) = ClipboardDeliveryBuffer.makeStream()
        let consumer = Task { () -> ClipboardMessage? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()?.message
        }
        try await waitForConsumer(buffer)
        let message = ClipboardMessage.grab(selection: .clipboard, types: Array(repeating: .png, count: 65))
        #expect(!buffer.yield(delivery(message)))
        #expect(await consumer.value == nil)
    }

    private func packet(_ bytes: [UInt8]) -> AgentClipboardDelivery {
        delivery(.data(selection: .clipboard, type: .png, bytes: bytes))
    }

    private func delivery(_ message: ClipboardMessage) -> AgentClipboardDelivery {
        let agent = AgentAuthorizationSource().current
        let negotiation = AgentAuthorizationSource().current
        return AgentClipboardDelivery(message: message,
            authorization: ClipboardAgentAuthorization(agent: agent, negotiation: negotiation))
    }

    private func waitForConsumer(_ buffer: ClipboardDeliveryBuffer) async throws {
        for _ in 0..<10_000 {
            if buffer.hasWaitingConsumer { return }
            await Task.yield()
        }
        Issue.record("Clipboard consumer did not suspend")
        throw WaitFailure.timeout
    }
    private enum WaitFailure: Error { case timeout }
}
