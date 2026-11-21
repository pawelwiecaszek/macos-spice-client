import SpiceAgent
import Synchronization

/// A single clipboard consumer with bounded payload storage and ordered controls.
/// Overflow ends delivery instead of silently replacing a GRAB, REQUEST or RELEASE.
public final class ClipboardDeliveryBuffer: Sendable {
    private typealias Waiter = CheckedContinuation<AgentClipboardDelivery?, Never>

    private struct State: Sendable {
        var events: [AgentClipboardDelivery] = []
        var payloadBytes = 0
        var waiter: Waiter?
        var finished = false
    }

    private enum NextAction {
        case wait
        case deliver(AgentClipboardDelivery?)
        case concurrentConsumer(Waiter)
    }

    private let state: Mutex<State>
    private let maximumEvents: Int
    private let maximumBytes: Int

    private init(maximumEvents: Int, maximumBytes: Int) {
        self.maximumEvents = min(64, max(1, maximumEvents))
        self.maximumBytes = min(ClipboardCodec.maxDataSize, max(1, maximumBytes))
        var initial = State()
        initial.events.reserveCapacity(self.maximumEvents)
        state = Mutex(initial)
    }

    /// Makes one unfolding stream, without an intermediate AsyncStream queue.
    /// Limits clamp to 1–64 events and 1 byte–32 MiB of DATA payloads. Control
    /// metadata is bounded separately (at most 64 types in each GRAB).
    public static func makeStream(maximumEvents: Int = 16, maximumBytes: Int = 32 * 1024 * 1024)
        -> (stream: AsyncStream<AgentClipboardDelivery>, buffer: ClipboardDeliveryBuffer) {
        let buffer = ClipboardDeliveryBuffer(maximumEvents: maximumEvents, maximumBytes: maximumBytes)
        let stream = AsyncStream(unfolding: { await buffer.next() }, onCancel: { buffer.finish() })
        return (stream, buffer)
    }

    /// False means delivery is terminal. The wire owner must retire the associated
    /// clipboard authority so an event already handed off cannot remain valid.
    @discardableResult
    public func yield(_ event: AgentClipboardDelivery) -> Bool {
        var waiter: Waiter?
        var direct: AgentClipboardDelivery?
        let accepted = state.withLock { state in
            guard !state.finished else { return false }
            let bytes = Self.payloadBytes(event)
            guard Self.hasBoundedMetadata(event), bytes <= maximumBytes else {
                waiter = Self.finish(&state)
                return false
            }
            if let waiting = state.waiter {
                state.waiter = nil
                waiter = waiting
                direct = event
                return true
            }
            guard state.events.count < maximumEvents, bytes <= maximumBytes - state.payloadBytes else {
                waiter = Self.finish(&state)
                return false
            }
            state.events.append(event)
            state.payloadBytes += bytes
            return true
        }
        waiter?.resume(returning: direct)
        return accepted
    }

    /// Discards queued replies and wakes a suspended consumer with EOF. Repeated
    /// finish/cancel calls are harmless; no stale queue is drained after shutdown.
    public func finish() {
        let waiter = state.withLock { Self.finish(&$0) }
        waiter?.resume(returning: nil)
    }

    /// Hardware-free synchronization point for suspension and cancellation tests.
    var hasWaitingConsumer: Bool { state.withLock { $0.waiter != nil } }

    private static func finish(_ state: inout State) -> Waiter? {
        guard !state.finished else { return nil }
        state.finished = true
        state.events.removeAll(keepingCapacity: true)
        state.payloadBytes = 0
        let waiter = state.waiter
        state.waiter = nil
        return waiter
    }

    private func next() async -> AgentClipboardDelivery? {
        await withTaskCancellationHandler {
            if Task.isCancelled { finish(); return nil }
            return await withCheckedContinuation { continuation in
                let action: NextAction = state.withLock { state in
                    if state.finished { return .deliver(nil) }
                    if !state.events.isEmpty {
                        let event = state.events.removeFirst()
                        state.payloadBytes -= Self.payloadBytes(event)
                        return .deliver(event)
                    }
                    if let previous = state.waiter {
                        _ = Self.finish(&state)
                        return .concurrentConsumer(previous)
                    }
                    state.waiter = continuation
                    return .wait
                }
                switch action {
                case .wait: break
                case .deliver(let event): continuation.resume(returning: event)
                case .concurrentConsumer(let previous):
                    previous.resume(returning: nil)
                    continuation.resume(returning: nil)
                }
            }
        } onCancel: { self.finish() }
    }

    private static func payloadBytes(_ event: AgentClipboardDelivery) -> Int {
        if case .data(_, _, let bytes) = event.message { return bytes.count }
        return 0
    }

    private static func hasBoundedMetadata(_ event: AgentClipboardDelivery) -> Bool {
        if case .grab(_, let types) = event.message { return types.count <= 64 }
        return true
    }
}
