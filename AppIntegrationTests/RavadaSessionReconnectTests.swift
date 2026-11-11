import AppKit
import Foundation
import SpiceKit
import Testing
@testable import SpiceClient

@MainActor
struct RavadaSessionReconnectTests {
    @Test func authorityIncludesAddressBasePathAndLoginEpochButNotPreferences() {
        let profile = RavadaPortalProfile(name: "Synthetic", address: "https://portal.example.invalid/vdi/")
        let identity = RavadaSessionOrigin(profile: profile, machineID: 42)
        #expect(identity.matches(profile))
        var changed = profile
        changed.name = "Renamed"; changed.isFavorite = true
        #expect(identity.matches(changed))
        changed.address = "https://portal.example.invalid/other/"
        #expect(!identity.matches(changed))
        changed = profile; changed.websiteDataStoreID = UUID()
        #expect(!identity.matches(changed))
        changed = profile; changed.id = UUID()
        #expect(!identity.matches(changed))
    }

    @Test func manualReconnectRejectsDuplicateClickAndCancelledLateTicket() async throws {
        let pending = PendingTicket()
        let controller = SessionController(profile: encryptedProfile(), origin: origin(), ravadaReconnect: { _ in
            pending.calls += 1
            return await withCheckedContinuation { pending.reply = $0 }
        })
        controller.reconnectNow(); controller.reconnectNow()
        try await wait { pending.reply != nil }
        #expect(pending.calls == 1)
        #expect(controller.canReconnect)
        #expect(!controller.canReconnectAutomatically)
        #expect(controller.maxReconnectAttempts == 1)
        controller.cancelReconnect()
        pending.reply?.resume(returning: RavadaReconnectTicket(profile: encryptedProfile()))
        pending.reply = nil
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.phase == .ended(nil))
        controller.stop()
    }

    @Test func closedControllerCannotBeginAnotherTicketRequest() async throws {
        let pending = PendingTicket()
        let controller = SessionController(profile: encryptedProfile(), origin: origin(), ravadaReconnect: { _ in
            pending.calls += 1
            return await withCheckedContinuation { pending.reply = $0 }
        })
        controller.reconnectNow()
        try await wait { pending.reply != nil }
        controller.stop()
        pending.reply?.resume(returning: RavadaReconnectTicket(profile: encryptedProfile())); pending.reply = nil
        controller.reconnectNow()
        for _ in 0..<20 { await Task.yield() }
        #expect(pending.calls == 1)
    }

    @Test func failedRavadaReadDoesNotAutomaticallyRetry() async throws {
        let pending = PendingTicket()
        let controller = SessionController(profile: encryptedProfile(), origin: origin(), ravadaReconnect: { _ in
            pending.calls += 1
            throw RavadaBrokerError.signInRequired
        })
        controller.reconnectNow()
        try await wait { if case .ended = controller.phase { return true }; return false }
        #expect(pending.calls == 1)
        #expect(controller.phase == .ended(RavadaBrokerError.signInRequired.localizedDescription))
        controller.stop()
    }

    @Test func partiallyEncryptedReconnectCannotWeakenProtectedChannels() {
        var previous = encryptedProfile()
        previous.port = 5900
        previous.secureChannels = .some([.main, .inputs])
        var next = previous
        #expect(RavadaConnectionFile.preservesEncryption(from: previous, to: next))
        next.secureChannels = .some([.main])
        #expect(!RavadaConnectionFile.preservesEncryption(from: previous, to: next))
        next.secureChannels = .some([.main, .inputs, .display])
        #expect(RavadaConnectionFile.preservesEncryption(from: previous, to: next))
        next.tlsPort = nil
        #expect(!RavadaConnectionFile.preservesEncryption(from: previous, to: next))
    }

    @Test func encryptedSessionNeverAcceptsPlainReconnectProfile() async throws {
        let controller = SessionController(profile: encryptedProfile(), origin: origin(), ravadaReconnect: { _ in
            var plain = ConnectionProfile(host: "guest.example.invalid")
            plain.port = 5900
            return RavadaReconnectTicket(profile: plain)
        })
        controller.reconnectNow()
        try await wait { if case .ended = controller.phase { return true }; return false }
        #expect(controller.phase == .ended(RavadaBrokerError.portalRequired.localizedDescription))
        controller.stop()
    }

    @Test func finalTicketAuthorityIsCheckedAfterAsyncProviderReturns() async throws {
        var validations = 0
        let controller = SessionController(profile: encryptedProfile(), origin: origin(), ravadaReconnect: { _ in
            RavadaReconnectTicket(profile: encryptedProfile(), validate: {
                validations += 1
                throw RavadaBrokerError.portalRequired
            })
        })
        controller.reconnectNow()
        try await wait { if case .ended = controller.phase { return true }; return false }
        #expect(validations == 1)
        #expect(controller.phase == .ended(RavadaBrokerError.portalRequired.localizedDescription))
        controller.stop()
    }

    @Test func replacementKeepsWindowFrameOriginAndPreferences() throws {
        let manager = SessionWindowManager.shared
        let preferences = AppSettings.shared.applying(RavadaPortalPreferences())
        let profile = encryptedProfile()
        let source = origin()
        #expect(manager.openSession(profile, settings: preferences, origin: source))
        let window = try #require(NSApp.windows.first { $0.title == profile.displayTitle })
        defer { window.close() }
        let old = try #require(manager.controller(for: window))
        window.setFrame(NSRect(x: 70, y: 80, width: 850, height: 650), display: false)
        let frame = window.frame
        let count = NSApp.windows.count
        manager.replace(old, with: profile, context: .init(attempt: 1, carryOver: .init(), lastFailure: nil))
        let new = try #require(manager.controller(for: window))
        #expect(new !== old)
        #expect(new.window === window)
        #expect(new.window?.frame == frame)
        #expect(new.origin == source)
        #expect(new.sessionSettings === preferences)
        #expect(NSApp.windows.count == count)
    }

    private func origin() -> SessionOrigin {
        .ravada(RavadaSessionOrigin(profile: .init(name: "Synthetic", address: "https://portal.example.invalid"), machineID: 42))
    }

    private func encryptedProfile() -> ConnectionProfile {
        var profile = ConnectionProfile(host: "guest.example.invalid")
        profile.tlsPort = 5901
        profile.title = "Synthetic reconnect test"
        return profile
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Reconnect did not reach the expected state")
        throw RavadaBrokerError.timedOut
    }
}

@MainActor
private final class PendingTicket {
    var calls = 0
    var reply: CheckedContinuation<RavadaReconnectTicket, Never>?
}
