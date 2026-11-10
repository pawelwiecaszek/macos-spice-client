import Foundation
import SpiceKit
import Testing
@testable import SpiceClient

@MainActor
struct SessionOriginTests {
    @Test func openingWithoutBrokerContextRetainsProxmoxRecognition() throws {
        let profile = try proxmoxProfile()
        let expected = ProxmoxVMRef(apiHost: "proxy.example.invalid", node: "node1", vmid: 101)
        let controller = SessionController(profile: profile)
        #expect(controller.origin == .proxmox(expected))
        #expect(controller.vmRef == expected)
    }

    @Test func plainConnectionWithoutBrokerContextRemainsManual() {
        let profile = ConnectionProfile(host: "guest.example.invalid")
        let controller = SessionController(profile: profile)
        #expect(controller.origin == .manual)
        #expect(controller.vmRef == nil)
        #expect(controller.canReconnect)
    }

    @Test func ravadaContextDoesNotInferProxmoxFromConnectionFileFields() throws {
        let profile = try proxmoxProfile()
        let origin = SessionOrigin.ravada(profileID: UUID(), machineID: 42)
        let controller = SessionController(profile: profile, origin: origin)
        #expect(controller.origin == origin)
        #expect(controller.vmRef == nil)
        // Provenance alone must not enable fresh-ticket reconnect or power control.
        #expect(!controller.canReconnect)
        #expect(!controller.canControlPower)
    }

    @Test func unrecognizedRavadaMachineKeepsProfileContextWithoutInventingIdentity() {
        let origin = SessionOrigin.ravada(profileID: UUID(), machineID: nil)
        let controller = SessionController(profile: ConnectionProfile(host: "guest.example.invalid"), origin: origin)
        #expect(controller.origin == origin)
        #expect(controller.vmRef == nil)
        // Ticketless sessions retain their existing direct reconnect behavior.
        #expect(controller.canReconnect)
    }

    @Test func explicitManualContextOverridesProxmoxLookingFields() throws {
        let controller = SessionController(profile: try proxmoxProfile(), origin: .manual)
        #expect(controller.origin == .manual)
        #expect(controller.vmRef == nil)
        #expect(!controller.canReconnect)
    }

    private func proxmoxProfile() throws -> ConnectionProfile {
        try VVFileParser.parse("""
        [virt-viewer]
        type=spice
        host=pvespiceproxy:synthetic:101:node1::synthetic
        proxy=http://proxy.example.invalid:3128
        tls-port=61000
        password=synthetic-ticket
        """).profile
    }
}
