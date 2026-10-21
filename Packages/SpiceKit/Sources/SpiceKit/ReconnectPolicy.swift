/// When and how often to reconnect after a session drops (M8).
///
/// Only network trouble starts automatic reconnection; a session the server ended on purpose
/// (guest shut down, another client took over) is left alone so two clients never fight
/// over one virtual machine. Attempts back off and stop after `delays.count` tries.
public struct ReconnectPolicy: Sendable, Equatable {
    /// Wait before attempt 1, 2, …; no more attempts afterwards.
    public var delays: [Duration]
    /// A session that stays up this long starts over at attempt 1 when it drops.
    public var stableAfter: Duration

    public init(delays: [Duration] = [1, 2, 4, 8, 15, 30, 30, 30].map { .seconds($0) },
                stableAfter: Duration = .seconds(60)) {
        self.delays = delays
        self.stableAfter = stableAfter
    }

    /// Wait before the given 1-based attempt, or `nil` to give up.
    public func delay(beforeAttempt attempt: Int) -> Duration? {
        guard attempt >= 1, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }

    /// Whether to try again after `failure`.
    /// - Parameters:
    ///   - wasConnected: the session that ended had been fully connected.
    ///   - reconnecting: the session that ended was itself a reconnection attempt.
    public func shouldReconnect(after failure: SessionFailure?, wasConnected: Bool, reconnecting: Bool) -> Bool {
        guard let failure else { return false }  // the user disconnected
        switch failure.recovery {
        case .automatic:
            return wasConnected || reconnecting
        case .manual:
            // While the network comes back a proxy may close or refuse us; keep trying
            // within the attempt budget, but never after a ticket was rejected.
            return reconnecting && !wasConnected && !failure.isAuthenticationFailure
        case .none:
            return false
        }
    }
}
