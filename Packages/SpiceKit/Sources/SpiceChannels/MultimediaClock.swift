import Synchronization

/// The wrapping server millisecond clock. Fresh, presentation-calibrated audio is
/// authoritative; main-channel updates remain available as an independent fallback.
public final class MultimediaClock: Sendable {
    public static let audioFreshness: Duration = .milliseconds(250)

    private struct Anchor: Sendable {
        let server: UInt32
        let at: ContinuousClock.Instant
    }

    private struct State: Sendable {
        var main: Anchor?
        var audio: Anchor?
        var audioEpoch: UInt64?
        var nextEpoch: UInt64 = 0
        var audioNotBefore: ContinuousClock.Instant?
        var audioDelay: UInt32?
    }

    private let state = Mutex(State())
    private let instant: @Sendable () -> ContinuousClock.Instant

    public init() { instant = { ContinuousClock.now } }

    /// Deterministic monotonic time for clock-authority tests, without sleeping.
    init(now: @escaping @Sendable () -> ContinuousClock.Instant) { instant = now }

    /// MAIN_INIT / MULTI_MEDIA_TIME always refresh the fallback, even while audio
    /// is authoritative. They do not refresh an old audio observation.
    public func set(_ serverTime: UInt32) {
        let at = instant()
        state.withLock { $0.main = Anchor(server: serverTime, at: at) }
    }

    /// Starts a new playback authority epoch. Older producers cannot change it.
    @discardableResult
    public func beginAudio() -> UInt64 {
        let now = instant()
        return state.withLock { state in
            state.nextEpoch &+= 1
            if state.nextEpoch == 0 { state.nextEpoch &+= 1 }
            state.audioEpoch = state.nextEpoch
            state.audio = nil
            state.audioDelay = nil
            state.audioNotBefore = now.advanced(by: .zero - Self.audioFreshness)
            return state.nextEpoch
        }
    }

    /// `time` is the audible server position effective at `at`, not a buffer
    /// target or an unadjusted source-render timestamp. Callers must retain the
    /// original observation instant rather than freshening a stale sample.
    @discardableResult
    public func updateAudio(time: UInt32, epoch: UInt64, at: ContinuousClock.Instant? = nil,
                            delayMilliseconds: UInt32? = nil) -> Bool {
        let now = instant()
        let observedAt = at ?? now
        let age = now - observedAt
        guard age >= .zero, age <= Self.audioFreshness else { return false }
        return state.withLock { state in
            guard state.audioEpoch == epoch,
                  state.audioNotBefore.map({ observedAt >= $0 }) ?? true,
                  state.audio.map({ observedAt >= $0.at }) ?? true else { return false }
            state.audio = Anchor(server: time, at: observedAt)
            state.audioDelay = delayMilliseconds
            return true
        }
    }

    /// Rebuffering/unknown timing falls back immediately. The same producer may
    /// recover with a newer observation; observations predating invalidation fail.
    @discardableResult
    public func invalidateAudio(epoch: UInt64) -> Bool {
        let now = instant()
        return state.withLock { state in
            guard state.audioEpoch == epoch else { return false }
            state.audio = nil
            state.audioDelay = nil
            state.audioNotBefore = now
            return true
        }
    }

    @discardableResult
    public func endAudio(epoch: UInt64) -> Bool {
        state.withLock { state in
            guard state.audioEpoch == epoch else { return false }
            state.audioEpoch = nil
            state.audio = nil
            state.audioDelay = nil
            state.audioNotBefore = nil
            return true
        }
    }

    /// Session replacement/teardown removes every anchor. Epoch IDs are not reused.
    public func reset() {
        state.withLock { state in
            state.main = nil
            state.audio = nil
            state.audioDelay = nil
            state.audioEpoch = nil
            state.audioNotBefore = nil
        }
    }

    /// Current server time, or nil when neither source has a usable observation.
    public var now: UInt32? {
        let now = instant()
        return state.withLock { state in
            if let audio = state.audio {
                let age = now - audio.at
                if age >= .zero, age <= Self.audioFreshness { return Self.advance(audio, to: now) }
            }
            return state.main.flatMap { Self.advance($0, to: now) }
        }
    }

    /// Fresh calibrated playback delay, including queued frames and downstream
    /// output. Nil is serialized using SPICE's no-audio/unknown sentinel.
    public var audioDelayMilliseconds: UInt32? {
        let now = instant()
        return state.withLock { state in
            guard let anchor = state.audio, now >= anchor.at,
                  now - anchor.at <= Self.audioFreshness else { return nil }
            return state.audioDelay
        }
    }

    private static func advance(_ anchor: Anchor, to now: ContinuousClock.Instant) -> UInt32? {
        let elapsed = now - anchor.at
        guard elapsed >= .zero else { return nil }
        let parts = elapsed.components
        // Reduce to the wrapping u32 domain before multiplying seconds; long
        // monotonic lifetimes must not overflow signed millisecond arithmetic.
        let ms = UInt32(truncatingIfNeeded: parts.seconds) &* 1000
            &+ UInt32(truncatingIfNeeded: parts.attoseconds / 1_000_000_000_000_000)
        return anchor.server &+ ms
    }
}
