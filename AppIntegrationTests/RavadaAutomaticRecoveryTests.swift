import Foundation
import SpiceKit
import Testing
@testable import SpiceClient

@MainActor
struct RavadaAutomaticRecoveryTests {
    @Test func transientBrokerFailuresBackOffAndStopAtEightAttempts() async throws {
        let fixture = RecoveryFixture()
        let controller = fixture.controller()
        defer { controller.stop() }
        fixture.drop(controller)
        try await fixture.wait { if case .ended = controller.phase { return true }; return false }
        #expect(fixture.calls == 8)
        #expect(fixture.delays == ReconnectPolicy().delays)
    }

    @Test func signInPermissionAndPolicyFailuresStopAfterOneRead() async throws {
        for error: RavadaBrokerError in [.signInRequired, .permissionDenied, .accessDenied, .portalRequired,
                                        .invalidResponse, .redirectRejected, .cancelled, .server(status: 404)] {
            let fixture = RecoveryFixture()
            fixture.error = error
            let controller = fixture.controller()
            fixture.drop(controller)
            try await fixture.wait { if case .ended = controller.phase { return true }; return false }
            #expect(fixture.calls == 1)
            #expect(fixture.delays == [.seconds(1)])
            controller.stop()
        }
    }

    @Test func disablingAutomaticRecoveryDuringBackoffPreventsTheTicketRead() async throws {
        let fixture = RecoveryFixture()
        fixture.disableDuringDelay = true
        let controller = fixture.controller()
        fixture.drop(controller)
        try await fixture.wait { if case .ended = controller.phase { return true }; return false }
        #expect(fixture.calls == 0)
        controller.stop()
    }

    @Test func disablingRecoveryDuringTicketReadSuppressesLateHandoff() async throws {
        let fixture = RecoveryFixture()
        let pending = AutoPendingTicket()
        fixture.ticketProvider = { await withCheckedContinuation { pending.reply = $0 } }
        let controller = fixture.controller()
        fixture.drop(controller)
        try await fixture.wait { pending.reply != nil }
        fixture.settings.reconnectAutomatically = false
        var profile = ConnectionProfile(host: "guest.example.invalid")
        profile.tlsPort = 5901
        pending.reply?.resume(returning: RavadaReconnectTicket(profile: profile))
        pending.reply = nil
        try await fixture.wait { if case .ended = controller.phase { return true }; return false }
        #expect(fixture.calls == 1)
        controller.stop()
    }

    @Test func retryClassifierOnlyPermitsTransientReadFailures() {
        #expect(RavadaRecoveryPolicy.mayRetry(RavadaBrokerError.unavailable))
        #expect(RavadaRecoveryPolicy.mayRetry(RavadaBrokerError.timedOut))
        #expect(RavadaRecoveryPolicy.mayRetry(RavadaBrokerError.server(status: 503)))
        #expect(!RavadaRecoveryPolicy.mayRetry(CancellationError()))
    }

    @Test func intentionalServerCloseAndAuthenticationNeverTriggerRecovery() async {
        for failure in [SessionFailure(message: "Server ended", recovery: .manual),
                        SessionFailure(message: "Denied", isAuthenticationFailure: true, recovery: .automatic),
                        SessionFailure(message: "TLS failure", recovery: .none)] {
            let fixture = RecoveryFixture()
            let controller = fixture.controller()
            controller.handle(.state(.connected))
            controller.handle(.state(.disconnected(failure)))
            for _ in 0..<20 { await Task.yield() }
            #expect(fixture.calls == 0)
            #expect(fixture.delays.isEmpty)
            controller.stop()
        }
        #expect(!RavadaRecoveryPolicy.shouldReconnect(after: nil, wasConnected: true, recovering: true))
    }

    @Test func initialFailureAndDisabledPreferenceDoNotRetry() async {
        for wasConnected in [false, true] {
            let fixture = RecoveryFixture()
            fixture.settings.reconnectAutomatically = !wasConnected
            let controller = fixture.controller()
            if wasConnected { controller.handle(.state(.connected)) }
            controller.handle(.state(.disconnected(.init(message: "Network", recovery: .automatic))))
            for _ in 0..<20 { await Task.yield() }
            #expect(fixture.calls == 0)
            controller.stop()
        }
    }

    @Test func offlineWaitingDoesNotConsumeAnAttemptAndCancellationReleasesWaiter() async throws {
        let fixture = RecoveryFixture()
        fixture.monitor.updatePath(false)
        let controller = fixture.controller()
        fixture.drop(controller)
        try await fixture.wait { fixture.monitor.pendingWaitCount == 1 }
        #expect(fixture.calls == 0)
        #expect(fixture.delays.isEmpty)
        controller.cancelReconnect()
        try await fixture.wait { fixture.monitor.pendingWaitCount == 0 }
        fixture.monitor.updatePath(true)
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.calls == 0)
        controller.stop()
    }

    @Test func pathLossDuringDelayIsRecheckedBeforeFetchingTicket() async throws {
        let fixture = RecoveryFixture()
        fixture.goOfflineDuringDelay = true
        fixture.error = .signInRequired
        let controller = fixture.controller()
        fixture.drop(controller)
        try await fixture.wait { fixture.monitor.pendingWaitCount == 1 }
        #expect(fixture.calls == 0)
        fixture.monitor.updatePath(true)
        try await fixture.wait { fixture.calls == 1 }
        controller.stop()
    }

    @Test func replacementAttemptContinuesBudgetAndFreshLaunchDoesNot() async throws {
        let fixture = RecoveryFixture()
        let controller = fixture.controller(context: .init(attempt: 7, automatic: true, carryOver: .init(), lastFailure: nil))
        controller.handle(.state(.disconnected(.init(message: "Network", recovery: .automatic))))
        try await fixture.wait { if case .ended = controller.phase { return true }; return false }
        #expect(fixture.calls == 1)
        #expect(fixture.delays == [.seconds(30)])
        controller.stop()
        #expect(!RavadaRecoveryPolicy.shouldReconnect(after: .init(message: "Network", recovery: .automatic),
                                                      wasConnected: false, recovering: false))
    }

    @Test func manualReconnectFailureDoesNotStartAnAutomaticLoop() async throws {
        let fixture = RecoveryFixture()
        let controller = fixture.controller()
        controller.reconnectNow()
        try await fixture.wait { if case .ended = controller.phase { return true }; return false }
        #expect(fixture.calls == 1)
        #expect(fixture.delays.isEmpty)
        controller.stop()
    }
}

@MainActor
private final class RecoveryFixture {
    let monitor = NetworkMonitor(startMonitoring: false, notificationCenter: NotificationCenter())
    let settings = AppSettings(persistChanges: false)
    var calls = 0
    var delays: [Duration] = []
    var error = RavadaBrokerError.unavailable
    var ticketProvider: (@MainActor () async -> RavadaReconnectTicket)?
    var goOfflineDuringDelay = false
    var disableDuringDelay = false

    init() { settings.reconnectAutomatically = true }

    func controller(context: ReconnectContext? = nil) -> SessionController {
        var profile = ConnectionProfile(host: "guest.example.invalid")
        profile.tlsPort = 5901
        let identity = RavadaSessionOrigin(profile: .init(name: "Synthetic", address: "https://portal.example.invalid"), machineID: 42)
        let environment = SessionRecoveryEnvironment(isOnline: { self.monitor.isOnline },
            waitUntilOnline: { await self.monitor.waitUntilOnline() }, sleep: { delay in
                self.delays.append(delay)
                if self.disableDuringDelay { self.settings.reconnectAutomatically = false }
                if self.goOfflineDuringDelay { self.monitor.updatePath(false) }
                await Task.yield()
            })
        return SessionController(profile: profile, settings: settings, reconnect: context, origin: .ravada(identity),
            recovery: environment, ravadaReconnect: { _ in
                self.calls += 1
                if let ticketProvider = self.ticketProvider { return await ticketProvider() }
                throw self.error
            })
    }

    func drop(_ controller: SessionController) {
        controller.handle(.state(.connected))
        controller.handle(.state(.disconnected(.init(message: "Synthetic network failure", recovery: .automatic))))
    }

    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Automatic recovery did not reach the expected state")
        throw CancellationError()
    }
}

@MainActor
private final class AutoPendingTicket {
    var reply: CheckedContinuation<RavadaReconnectTicket, Never>?
}
