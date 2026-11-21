import SpiceKit

/// Recover transport failures without competing with intentional server disconnects.
enum RavadaRecoveryPolicy {
    static func shouldReconnect(after failure: SessionFailure?, wasConnected: Bool, recovering: Bool) -> Bool {
        guard let failure, !failure.isAuthenticationFailure, failure.recovery == .automatic else { return false }
        return wasConnected || recovering
    }

    static func mayRetry(_ error: any Error) -> Bool {
        guard let error = error as? RavadaBrokerError else { return false }
        switch error {
        case .unavailable, .timedOut: return true
        case .server(let status): return (500...599).contains(status)
        default: return false
        }
    }
}
