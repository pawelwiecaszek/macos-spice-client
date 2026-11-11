import Foundation
import SpiceKit

/// Production timing/availability with deterministic substitutes for recovery tests.
@MainActor
struct SessionRecoveryEnvironment {
    var policy = ReconnectPolicy()
    var isOnline: @MainActor () -> Bool
    var waitUntilOnline: @MainActor () async -> Void
    var sleep: @MainActor (Duration) async throws -> Void

    static var live: Self {
        Self(isOnline: { NetworkMonitor.shared.isOnline },
             waitUntilOnline: { await NetworkMonitor.shared.waitUntilOnline() },
             sleep: { try await Task.sleep(for: $0) })
    }
}
