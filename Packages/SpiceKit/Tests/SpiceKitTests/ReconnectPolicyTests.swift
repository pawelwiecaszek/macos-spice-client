import Testing
@testable import SpiceKit

@Suite("Reconnect policy (M8)")
struct ReconnectPolicyTests {
    let policy = ReconnectPolicy()

    @Test func failuresAreClassified() {
        #expect(SessionFailure(TransportError.timedOut).recovery == .automatic)
        #expect(SessionFailure(TransportError.connectionFailed("reset")).recovery == .automatic)
        #expect(SessionFailure(ChannelError.migrationUnsupported).recovery == .automatic)
        #expect(SessionFailure(TransportError.closed).recovery == .manual)
        #expect(SessionFailure(ChannelError.serverDisconnected(reason: 0)).recovery == .manual)
        #expect(SessionFailure(TransportError.proxyRefused(status: 502)).recovery == .manual)
        let expired = SessionFailure(TransportError.proxyRefused(status: 403))
        #expect(expired.isAuthenticationFailure)
        #expect(SessionFailure(TransportError.tlsVerificationFailed("x")).recovery == .none)
        #expect(SessionFailure(TransportError.insecureConfiguration("x")).recovery == .none)
        #expect(SessionFailure(TransportError.protocolViolation("x")).recovery == .none)
    }

    @Test func networkDropsReconnect() {
        let drop = SessionFailure(TransportError.timedOut)
        #expect(policy.shouldReconnect(after: drop, wasConnected: true, reconnecting: false))
        #expect(policy.shouldReconnect(after: drop, wasConnected: false, reconnecting: true))
        // A first connection that never came up is reported, not retried.
        #expect(!policy.shouldReconnect(after: drop, wasConnected: false, reconnecting: false))
    }

    @Test func serverEndedSessionsStayClosed() {
        let closed = SessionFailure(TransportError.closed)
        #expect(!policy.shouldReconnect(after: closed, wasConnected: true, reconnecting: false))
        #expect(!policy.shouldReconnect(after: closed, wasConnected: true, reconnecting: true))
        #expect(policy.shouldReconnect(after: closed, wasConnected: false, reconnecting: true))
        let rejected = SessionFailure(TransportError.authenticationFailed(.permissionDenied))
        #expect(!policy.shouldReconnect(after: rejected, wasConnected: false, reconnecting: true))
        #expect(!policy.shouldReconnect(after: nil, wasConnected: true, reconnecting: true))
        let insecure = SessionFailure(TransportError.tlsVerificationFailed("x"))
        #expect(!policy.shouldReconnect(after: insecure, wasConnected: false, reconnecting: true))
    }

    @Test func attemptsBackOffAndStop() {
        #expect(policy.delay(beforeAttempt: 0) == nil)
        #expect(policy.delay(beforeAttempt: 1) == .seconds(1))
        #expect(policy.delay(beforeAttempt: 4) == .seconds(8))
        #expect(policy.delay(beforeAttempt: 8) == .seconds(30))
        #expect(policy.delay(beforeAttempt: 9) == nil)
    }
}
