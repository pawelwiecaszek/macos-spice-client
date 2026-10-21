import Foundation
import Testing
@testable import SpiceKit

private let testCA = try! String(contentsOf: URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/tls/test-server.pem"), encoding: .utf8)

/// Audit finding 2: supplied trust settings must be honoured or rejected, never weakened.
@Suite("Endpoint security configuration")
struct EndpointSecurityTests {
    private func profile(ca: String? = nil, subject: String? = nil) -> ConnectionProfile {
        var profile = ConnectionProfile(host: "pve")
        profile.tlsPort = 61000
        profile.caPEM = ca
        profile.hostSubject = subject
        return profile
    }

    @Test func validSettingsAreKept() throws {
        let endpoint = try SpiceSession.endpoint(for: profile(ca: testCA, subject: "OU=PVE Cluster Node,O=Proxmox,CN=pve"))
        #expect(endpoint.trustAnchors.count == 1)
        #expect(endpoint.hostSubject?.count == 3)
    }

    @Test func unreadableCAIsRejected() {
        #expect(throws: TransportError.self) {
            try SpiceSession.endpoint(for: profile(ca: "-----BEGIN CERTIFICATE-----\n!!!\n-----END CERTIFICATE-----"))
        }
        #expect(throws: TransportError.self) { try SpiceSession.endpoint(for: profile(ca: "not a pem")) }
        // One good certificate followed by a broken one: the whole CA setting is rejected.
        let mixed = testCA + "\n-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"
        #expect(throws: TransportError.self) { try SpiceSession.endpoint(for: profile(ca: mixed)) }
    }

    @Test func unreadableSubjectIsRejected() {
        #expect(throws: TransportError.self) { try SpiceSession.endpoint(for: profile(subject: "no-equals")) }
    }

    @Test func sessionWithBadSettingsFailsInsteadOfConnecting() async {
        let session = SpiceSession(profile: profile(subject: "garbage"))
        await session.connect()
        var states: [SessionState] = []
        for await event in session.events {
            if case .state(let state) = event { states.append(state) }
            if case .state(.disconnected) = event { break }
        }
        guard case .disconnected(let failure?) = states.last else {
            Issue.record("expected a failure, got \(states)")
            return
        }
        #expect(failure.message.contains("security settings"))
    }
}
