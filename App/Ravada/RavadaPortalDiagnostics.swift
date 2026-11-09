import Foundation

/// Bounded, in-memory counters only. No URLs, credentials, guest data or error text.
struct RavadaPortalDiagnostics {
    enum Event: String, CaseIterable {
        case pageLoads, signInPages, downloadsStarted, filesValidated, sessionsOpened
        case userCancellations, ignoredNavigationCancellations, rejectedDownloads, failures
    }

    private var counts: [Event: Int] = [:]
    private var lastFailure: RavadaPortalFailure?

    mutating func record(_ event: Event) {
        counts[event] = min((counts[event] ?? 0) + 1, 1_000_000)
    }

    mutating func record(_ failure: RavadaPortalFailure) {
        record(.failures)
        lastFailure = failure
    }

    var summary: String {
        var lines = ["Ravada portal diagnostics v1 (content-free)"]
        lines += Event.allCases.map { "\($0.rawValue): \(counts[$0] ?? 0)" }
        if let lastFailure {
            lines.append("lastFailure: \(lastFailure.kind.rawValue)")
            lines.append("lastFailurePhase: \(lastFailure.phase.rawValue)")
        }
        return lines.joined(separator: "\n")
    }
}
