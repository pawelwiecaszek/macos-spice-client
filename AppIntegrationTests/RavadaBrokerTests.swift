import Foundation
import SpiceKit
import Testing
import WebKit
@testable import SpiceClient

@MainActor
struct RavadaBrokerTests {
    private let portal = URL(string: "https://portal.example.invalid/vdi/")!
    private let page = URL(string: "https://portal.example.invalid/vdi/machines")!
    private let catalogURL = "https://portal.example.invalid/vdi/list_machines_user.json"

    private func response(status: Int = 200, url: String? = nil, body: String = "[]") -> [String: Any] {
        ["status": status, "url": url ?? catalogURL, "contentType": "application/json", "body": body]
    }

    @Test func fixedEndpointReadUsesBrowserOriginAndDecodesAuthorizedCatalog() async throws {
        let transport = try RavadaBrowserTransport(portalURL: portal, pageURL: { page }) { script, args in
            #expect(args["endpointURL"] as? String == catalogURL)
            #expect(args["byteLimit"] as? Int == RavadaCatalog.maxResponseBytes)
            #expect(script.contains("credentials: 'same-origin'"))
            #expect(script.contains("redirect: 'error'"))
            #expect(script.contains("mode: 'same-origin'"))
            #expect(script.contains("referrerPolicy: 'no-referrer'"))
            return response()
        }
        #expect(try await transport.catalog().entries.isEmpty)
    }

    @Test func crossOriginPageCannotIssueAnAuthenticatedRead() async throws {
        let transport = try RavadaBrowserTransport(portalURL: portal,
            pageURL: { URL(string: "https://identity.example.invalid/login") }) { _, _ in
                Issue.record("Must not invoke JavaScript on an identity provider")
                return response()
            }
        await #expect(throws: RavadaBrokerError.signInRequired) { try await transport.catalog() }
    }

    @Test func crossOriginAndUnexpectedResponseURLsAreRejected() async throws {
        for url in ["https://other.example.invalid/list_machines_user.json", "https://portal.example.invalid/vdi/login"] {
            let transport = try RavadaBrowserTransport(portalURL: portal, pageURL: { page }) { _, _ in response(url: url) }
            await #expect(throws: RavadaBrokerError.redirectRejected) { try await transport.catalog() }
        }
    }

    @Test func transportFailureBodiesAreNotExposed() async throws {
        let transport = try RavadaBrowserTransport(portalURL: portal, pageURL: { page }) { _, _ in
            throw NSError(domain: "private.invalid", code: 1, userInfo: [NSLocalizedDescriptionKey: "synthetic secret"])
        }
        await #expect(throws: RavadaBrokerError.unavailable) { try await transport.catalog() }
    }

    @Test func browserReportedLimitsAndStatusAreMapped() async throws {
        for (failure, expected) in [("timeout", RavadaBrokerError.timedOut), ("size", .responseTooLarge), ("origin", .redirectRejected)] {
            let transport = try RavadaBrowserTransport(portalURL: portal, pageURL: { page }) { _, _ in ["failure": failure] }
            await #expect(throws: expected) { try await transport.catalog() }
        }
        let denied = try RavadaBrowserTransport(portalURL: portal, pageURL: { page }) { _, _ in response(status: 403) }
        await #expect(throws: RavadaBrokerError.permissionDenied) { try await denied.catalog() }
    }

    @Test func navigationDuringReadRejectsLateResult() async throws {
        var current: URL? = page
        let transport = try RavadaBrowserTransport(portalURL: portal, pageURL: { current }) { _, _ in
            current = portal
            return response()
        }
        await #expect(throws: RavadaBrokerError.cancelled) { try await transport.catalog() }
    }

    @Test func checkCancellationSuppressesLateSuccessAndError() async throws {
        var resume: CheckedContinuation<RavadaCatalog, any Error>?
        let check = RavadaCatalogCheck(read: {
            try await withCheckedThrowingContinuation { resume = $0 }
        }, cancel: {})
        check.check()
        while resume == nil { await Task.yield() }
        check.cancel()
        resume?.resume(returning: try RavadaCatalog.decode(Data("[]".utf8), status: 200, contentType: "application/json"))
        await Task.yield()
        #expect(!check.isChecking)
        #expect(check.summary == nil)
    }

    @Test func displayIdentityRequiresExactOriginBaseRouteAndSPICEDriver() throws {
        for route in ["machine/display/spice/42.vv", "machine/display/spice-tls/42.tls.vv"] {
            #expect(RavadaPortalConfiguration.machineID(displayURL: URL(string: route, relativeTo: portal)?.absoluteURL, portalURL: portal) == 42)
        }
        for address in ["https://other.example.invalid/vdi/machine/display/spice/42.vv",
                        "https://portal.example.invalid/machine/display/spice/42.vv",
                        "https://portal.example.invalid/vdi/machine/display/rdp/42.vv",
                        "https://portal.example.invalid/vdi/machine/display/spice/42.vv?ticket=synthetic",
                        "https://portal.example.invalid/vdi/machine/display/spice/0.vv",
                        "https://portal.example.invalid/vdi/machine/display/spice/%34%32.vv"] {
            #expect(RavadaPortalConfiguration.machineID(displayURL: URL(string: address), portalURL: portal) == nil)
        }
    }

    @Test func verifiedMachineIdentitySurvivesAsyncParsingHandoff() async {
        var deliveredID: Int?
        let model = RavadaPortalModel(portalURL: portal,
            readFile: { _ in .success(ConnectionProfile(host: "guest.example.invalid")) },
            openConnectionWithIdentity: { _, id in deliveredID = id; return true })
        await model.openDownloadedConnectionFile(at: URL(fileURLWithPath: "/unused-synthetic.vv"), machineID: 42)
        #expect(deliveredID == 42)
        model.stop()
    }
}
