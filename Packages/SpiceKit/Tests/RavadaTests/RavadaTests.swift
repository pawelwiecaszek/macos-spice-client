import Foundation
import Testing
@testable import Ravada

struct RavadaTests {
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ravada/\(name).json")
        return try Data(contentsOf: url)
    }

    @Test func ordinaryCatalogPreservesNestedCloneIdentityAndStandaloneRows() throws {
        let catalog = try RavadaCatalog.decode(fixture("ordinary"), status: 200, contentType: "application/json; charset=utf-8")
        #expect(catalog.entries.map(\.id) == [10, 99])
        let clone = try #require(catalog.entries.first?.clones.first)
        #expect(clone.id == 42)
        #expect(clone.isActive == true)
        #expect(clone.isLocked == false)
        #expect(clone.canRemove == false)
        #expect(catalog.entries[1].machine.isActive == false)
    }

    @Test func adminVisibilityIsServerControlledAndUnknownPolicyIsNotPermission() throws {
        let catalog = try RavadaCatalog.decode(fixture("admin"), status: 200, contentType: "application/json")
        let clone = try #require(catalog.entries.first?.clones.first)
        #expect(clone.canRemove == nil)
        #expect(clone.rawState == "future-state")
        #expect(clone.isLocked == true)
        #expect(try RavadaCatalog.decode(Data("[]".utf8), status: 200, contentType: "application/json").entries.isEmpty)
    }

    @Test(arguments: [401, 403, 302, 500]) func statusFailuresAreTyped(status: Int) {
        let expected: RavadaBrokerError = switch status {
        case 401: .signInRequired
        case 403: .permissionDenied
        case 302: .redirectRejected
        default: .server(status: 500)
        }
        #expect(throws: expected) { try RavadaCatalog.decode(Data("{}".utf8), status: status, contentType: "application/json") }
    }

    @Test(arguments: [200, 403]) func htmlLoginNeverBecomesAnEmptyAuthorizedCatalog(status: Int) {
        #expect(throws: status == 403 ? RavadaBrokerError.accessDenied : .signInRequired) {
            try RavadaCatalog.decode(Data("<html>Sign in</html>".utf8), status: status, contentType: "text/html")
        }
    }

    @Test(arguments: ["{}", "[{\"id\":0,\"name\":\"bad\"}]", "[{\"id\":1}]", "[{\"id\":1,\"name\":\"A\"},{\"id\":1,\"name\":\"B\"}]"])
    func invalidCatalogFailsClosed(json: String) {
        #expect(throws: RavadaBrokerError.invalidResponse) {
            try RavadaCatalog.decode(Data(json.utf8), status: 200, contentType: "application/json")
        }
    }

    @Test func boundedPayloadAndItemCount() {
        #expect(throws: RavadaBrokerError.responseTooLarge) {
            try RavadaCatalog.decode(Data(repeating: 32, count: RavadaCatalog.maxResponseBytes + 1), status: 200, contentType: "application/json")
        }
        let list = (1...(RavadaCatalog.maxMachines + 1)).map { "{\"id\":\($0),\"name\":\"Synthetic\"}" }.joined(separator: ",")
        #expect(throws: RavadaBrokerError.invalidResponse) {
            try RavadaCatalog.decode(Data("[\(list)]".utf8), status: 200, contentType: "application/json")
        }
    }

    @Test(arguments: ["https://portal.example.invalid", "https://portal.example.invalid/vdi", "https://portal.example.invalid/vdi/"])
    func catalogPreservesConfiguredReverseProxyBase(address: String) throws {
        let endpoint = try RavadaEndpoint(portalURL: #require(URL(string: address)))
        #expect(endpoint.catalogURL.path == (address.contains("/vdi") ? "/vdi/list_machines_user.json" : "/list_machines_user.json"))
        #expect(!endpoint.contains(try #require(URL(string: "https://other.example.invalid/"))))
        #expect(!endpoint.contains(try #require(URL(string: "https://portal.example.invalid:444/"))))
    }

    @Test(arguments: ["http://portal.example.invalid/", "https://user@portal.example.invalid/", "https://portal.example.invalid/?secret=x", "https://portal.example.invalid/a%2Fb/", "https://portal.example.invalid/a/../"])
    func ambiguousBasesAreRejected(address: String) throws {
        #expect(throws: RavadaBrokerError.invalidAddress) {
            try RavadaEndpoint(portalURL: #require(URL(string: address)))
        }
    }
}
