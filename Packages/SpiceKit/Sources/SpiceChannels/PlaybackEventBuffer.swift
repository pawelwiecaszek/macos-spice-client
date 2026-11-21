import Synchronization

public enum PlaybackDeliveryFailure: Error, Sendable, Equatable {
    case packetLimit
    case controlLimit
    case eventLimit
}

/// One playback consumer with bounded audio and ordered control delivery. Audio
/// pressure purges queued packets and inserts an explicit discontinuity; control
/// pressure terminates playback rather than silently losing START or STOP.
public final class PlaybackEventBuffer: Sendable {
    private typealias Waiter = CheckedContinuation<PlaybackEvent?, Never>

    private struct State: Sendable {
        var events: [PlaybackEvent] = []
        var audioBytes = 0
        var controlCount = 0
        var waiter: Waiter?
        var finished = false
        var terminalStop = false
        var streamClaimed = false
        var failure: PlaybackDeliveryFailure?
    }

    private enum NextAction {
        case wait
        case deliver(PlaybackEvent?)
        case concurrentConsumer(Waiter)
    }

    private let state: Mutex<State>
    private let maxEvents: Int
    private let maxControls: Int
    private let maxAudioBytes: Int
    private static let maxPacketBytes = 64 * 1024

    public init() {
        maxEvents = 500
        maxControls = 64
        maxAudioBytes = 8 * 1024 * 1024
        var initial = State()
        initial.events.reserveCapacity(maxEvents)
        state = Mutex(initial)
    }

    /// Smaller bounds support deterministic overload tests without large payloads.
    init?(maxEvents: Int, maxControls: Int, maxAudioBytes: Int) {
        guard (1...500).contains(maxEvents), (1...min(64, maxEvents)).contains(maxControls),
              (1...8 * 1024 * 1024).contains(maxAudioBytes) else { return nil }
        self.maxEvents = maxEvents
        self.maxControls = maxControls
        self.maxAudioBytes = maxAudioBytes
        var initial = State()
        initial.events.reserveCapacity(maxEvents)
        state = Mutex(initial)
    }

    public static func makeStream() -> (stream: AsyncStream<PlaybackEvent>, buffer: PlaybackEventBuffer) {
        let buffer = PlaybackEventBuffer()
        return (buffer.stream(), buffer)
    }

    /// Claim the single consumer stream once. There is no second AsyncStream
    /// buffer: unfolding pulls directly from this queue. Cancellation closes it.
    public func stream() -> AsyncStream<PlaybackEvent> {
        let claimed = state.withLock { state in
            guard !state.streamClaimed else { return false }
            state.streamClaimed = true
            return true
        }
        guard claimed else { return AsyncStream { $0.finish() } }
        return AsyncStream(unfolding: { await self.next() }, onCancel: { self.cancel() })
    }

    /// Returns false once playback must end. Resume waiting consumers outside the
    /// mutex so resumed task execution never re-enters a held lock.
    @discardableResult
    public func yield(_ event: PlaybackEvent) -> Bool {
        var delivery: (Waiter, PlaybackEvent)?
        let accepted = state.withLock { state in
            guard !state.finished else { return false }
            let bytes = Self.audioBytes(event)
            let control = Self.isControl(event)
            guard bytes <= Self.maxPacketBytes, bytes <= maxAudioBytes else {
                let waiter = Self.finish(&state, failure: .packetLimit)
                if let waiter { delivery = (waiter, .stop) }
                return false
            }
            if let waiter = state.waiter {
                state.waiter = nil
                delivery = (waiter, event)
                return true
            }
            guard !control || state.controlCount < maxControls else {
                let waiter = Self.finish(&state, failure: .controlLimit)
                if let waiter { delivery = (waiter, .stop) }
                return false
            }
            let explicitDiscontinuity: Bool
            if case .discontinuity = event { explicitDiscontinuity = true }
            else { explicitDiscontinuity = false }
            if explicitDiscontinuity || state.events.count == maxEvents || state.audioBytes + bytes > maxAudioBytes {
                // Keep controls in wire order; all surviving packets come after
                // the marker, so no dropped interval can appear continuous.
                state.events.removeAll { !Self.isControl($0) }
                state.audioBytes = 0
                let needed = explicitDiscontinuity ? 1 : 2
                guard state.events.count + needed <= maxEvents else {
                    let waiter = Self.finish(&state, failure: .eventLimit)
                    if let waiter { delivery = (waiter, .stop) }
                    return false
                }
                state.events.append(.discontinuity)
            }
            if !explicitDiscontinuity { state.events.append(event) }
            state.audioBytes += bytes
            if control { state.controlCount += 1 }
            return true
        }
        if let (waiter, event) = delivery { waiter.resume(returning: event) }
        return accepted
    }

    /// Channel/session termination discards pending audio and delivers STOP once,
    /// then EOF. Repeated close is harmless, including while next() is suspended.
    public func finish() {
        let waiter = state.withLock { Self.finish(&$0) }
        waiter?.resume(returning: .stop)
    }

    /// The first delivery-limit failure survives normal close/cancellation so
    /// the producer can distinguish overload from an intentional shutdown.
    public var failure: PlaybackDeliveryFailure? { state.withLock { $0.failure } }

    /// Synchronization diagnostic used by hardware-free suspension/race tests.
    var hasWaitingConsumer: Bool { state.withLock { $0.waiter != nil } }

    private func cancel() {
        let waiter = state.withLock { state in
            let waiter = state.waiter
            state.waiter = nil
            state.events.removeAll(keepingCapacity: true)
            state.audioBytes = 0
            state.controlCount = 0
            state.finished = true
            state.terminalStop = false
            return waiter
        }
        waiter?.resume(returning: nil)
    }

    private static func finish(_ state: inout State, failure: PlaybackDeliveryFailure? = nil) -> Waiter? {
        guard !state.finished else { return nil }
        state.finished = true
        state.failure = failure
        state.events.removeAll(keepingCapacity: true)
        state.audioBytes = 0
        state.controlCount = 0
        let waiter = state.waiter
        state.waiter = nil
        state.terminalStop = waiter == nil
        return waiter
    }

    private func next() async -> PlaybackEvent? {
        await withTaskCancellationHandler {
            if Task.isCancelled { cancel(); return nil }
            return await withCheckedContinuation { continuation in
                let action: NextAction = state.withLock { state in
                    if state.finished {
                        if state.terminalStop {
                            state.terminalStop = false
                            return .deliver(.stop)
                        }
                        return .deliver(nil)
                    }
                    if !state.events.isEmpty {
                        let event = state.events.removeFirst()
                        state.audioBytes -= Self.audioBytes(event)
                        if Self.isControl(event) { state.controlCount -= 1 }
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
                    previous.resume(returning: .stop)
                    continuation.resume(returning: nil)
                }
            }
        } onCancel: { self.cancel() }
    }

    private static func audioBytes(_ event: PlaybackEvent) -> Int {
        if case .data(_, _, let bytes) = event { return bytes.count }
        return 0
    }

    private static func isControl(_ event: PlaybackEvent) -> Bool {
        switch event {
        case .data, .discontinuity: return false
        default: return true
        }
    }
}
