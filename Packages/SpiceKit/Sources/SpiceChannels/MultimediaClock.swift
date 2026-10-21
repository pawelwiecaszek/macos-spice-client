import Synchronization

/// The server's multimedia clock (milliseconds, wrapping u32), learned from the main
/// channel's INIT and MULTI_MEDIA_TIME messages and advanced locally in between. Video
/// stream reports and (later) audio sync are expressed in this time base.
public final class MultimediaClock: Sendable {
    private let state = Mutex<(server: UInt32, at: ContinuousClock.Instant)?>(nil)

    public init() {}

    public func set(_ serverTime: UInt32) {
        state.withLock { $0 = (serverTime, ContinuousClock.now) }
    }

    /// Current server time, or `nil` before the first sync.
    public var now: UInt32? {
        state.withLock { value in
            guard let value else { return nil }
            let elapsed = ContinuousClock.now - value.at
            let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000  // 1 ms = 10^15 as
            return value.server &+ UInt32(truncatingIfNeeded: ms)
        }
    }
}
