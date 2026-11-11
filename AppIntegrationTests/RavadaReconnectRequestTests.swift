import Foundation
import SpiceKit
import Testing
@testable import SpiceClient

@MainActor
struct RavadaReconnectRequestTests {
    @Test func runningCloneFetchesFreshTicketAndRechecksAuthorizationWithoutStart() async throws {
        let fixture = ReconnectRequestFixture()
        let first = try await fixture.profile()
        let second = try await fixture.profile()
        #expect(first.password !== second.password)
        #expect(second.password?.withBytes { $0 == Array("synthetic-2".utf8) } == true)
        #expect(first.fullscreen == false)
        #expect(fixture.routes == [
            .catalog, .machineInfo(42), .catalog, .machineInfo(42),
            .connection(machineID: 42, driver: "spice-tls", fileExtension: "tls.vv"),
            .catalog, .machineInfo(42), .catalog, .machineInfo(42),
            .connection(machineID: 42, driver: "spice-tls", fileExtension: "tls.vv")
        ])
    }

    @Test func stoppedOrLockedOrMissingCatalogIdentityNeverRequestsTicket() async {
        for catalog in ["[]", ReconnectRequestFixture.catalog(active: 0),
                        ReconnectRequestFixture.catalog(locked: "1"),
                        ReconnectRequestFixture.catalog(locked: "null"),
                        #"[{"id":42,"name":"Base","is_base":1,"is_active":1,"is_locked":0}]"#] {
            let fixture = ReconnectRequestFixture()
            fixture.catalogBody = catalog
            await #expect(throws: RavadaBrokerError.portalRequired) { try await fixture.profile() }
            #expect(fixture.routes == [.catalog])
        }
    }

    @Test func authorizationRevokedBeforeTicketIsNotReused() async {
        let fixture = ReconnectRequestFixture()
        fixture.catalogAfterFirst = "[]"
        await #expect(throws: RavadaBrokerError.portalRequired) { try await fixture.profile() }
        #expect(fixture.ticketReads == 0)
        #expect(fixture.catalogReads == 2)
    }

    @Test func loginAndMetadataDenialsKeepFixedErrorCategories() async {
        for status in [401, 403] {
            let fixture = ReconnectRequestFixture()
            fixture.catalogStatus = status
            await #expect(throws: status == 401 ? RavadaBrokerError.signInRequired : .permissionDenied) {
                try await fixture.profile()
            }
            #expect(fixture.ticketReads == 0)
        }
        let fixture = ReconnectRequestFixture()
        fixture.metadataStatus = 403
        await #expect(throws: RavadaBrokerError.permissionDenied) { try await fixture.profile() }
        #expect(fixture.ticketReads == 0)
    }

    @Test func changedOrStoppedMetadataNeverFetchesTicket() async {
        for metadata in [ReconnectRequestFixture.metadata(id: 43),
                         ReconnectRequestFixture.metadata(active: 0),
                         ReconnectRequestFixture.metadata(base: 1),
                         ReconnectRequestFixture.metadata(hibernated: "1"),
                         ReconnectRequestFixture.metadata(hibernated: "null"),
                         ReconnectRequestFixture.metadata(pending: "null"),
                         ReconnectRequestFixture.metadata(pending: "-1")] {
            let fixture = ReconnectRequestFixture()
            fixture.metadataBody = metadata
            await #expect(throws: RavadaBrokerError.portalRequired) { try await fixture.profile() }
            #expect(fixture.ticketReads == 0)
        }
    }

    @Test func advertisedTLSNeverFallsBackToPlainDisplay() async {
        let fixture = ReconnectRequestFixture()
        fixture.metadataBody = ReconnectRequestFixture.metadata(displays:
            #"[{"driver":"spice","file_extension":"vv","is_active":1,"port":5900},{"driver":"spice-tls","is_active":0}]"#)
        await #expect(throws: RavadaBrokerError.portalRequired) { try await fixture.profile() }
        #expect(fixture.ticketReads == 0)
    }

    @Test func pendingCatalogWorkIsWaitedOutWithOneSharedReadBudget() async throws {
        let fixture = ReconnectRequestFixture()
        fixture.pendingReadsPerCatalog = 1
        _ = try await fixture.profile()
        #expect(fixture.infoReads == 4)
        #expect(fixture.sleeps == 2)
        #expect(fixture.ticketReads == 1)

        let blocked = ReconnectRequestFixture()
        blocked.metadataBody = ReconnectRequestFixture.metadata(pending: "1")
        await #expect(throws: RavadaBrokerError.timedOut) { try await blocked.profile() }
        #expect(blocked.infoReads == 90)
        #expect(blocked.ticketReads == 0)
    }

    @Test func plainFileFromTLSRouteCannotReplaceSession() async {
        let fixture = ReconnectRequestFixture()
        fixture.ticketBody = "[virt-viewer]\ntype=spice\nhost=guest.example.invalid\nport=5900\n"
        await #expect(throws: RavadaBrokerError.portalRequired) { try await fixture.profile() }
        #expect(fixture.ticketReads == 1)
    }

    @Test func wrongMIMEAndInvalidFileAreRejectedWithoutExposingBodies() async {
        let fixture = ReconnectRequestFixture()
        fixture.ticketMIME = "text/html"
        await #expect(throws: RavadaBrokerError.signInRequired) { try await fixture.profile() }
        fixture.ticketMIME = "application/x-virt-viewer"
        fixture.ticketBody = "invalid connection"
        await #expect(throws: RavadaBrokerError.invalidResponse) { try await fixture.profile() }
    }

    @Test func invalidatedIdentityBeforeOrAfterResponseSuppressesHandoff() async {
        let before = ReconnectRequestFixture()
        before.valid = false
        await #expect(throws: RavadaBrokerError.cancelled) { try await before.profile() }
        #expect(before.routes.isEmpty)

        let late = ReconnectRequestFixture()
        late.invalidateAfterTicket = true
        await #expect(throws: RavadaBrokerError.cancelled) { try await late.profile() }
        #expect(late.ticketReads == 1)
    }

    @Test func cancelledTaskDoesNotReadCatalog() async {
        let fixture = ReconnectRequestFixture()
        let task = Task { try await fixture.profile() }
        task.cancel()
        await #expect(throws: RavadaBrokerError.cancelled) { try await task.value }
        #expect(fixture.routes.isEmpty)
    }

    @Test func cancellationDuringExistingWorkStopsBeforeTicket() async {
        let fixture = ReconnectRequestFixture()
        fixture.metadataBody = ReconnectRequestFixture.metadata(pending: "1")
        fixture.invalidateDuringSleep = true
        await #expect(throws: RavadaBrokerError.cancelled) { try await fixture.profile() }
        #expect(fixture.infoReads == 1)
        #expect(fixture.ticketReads == 0)
    }
}

@MainActor
private final class ReconnectRequestFixture {
    var routes: [RavadaBrokerRequest] = []
    var catalogReads = 0
    var infoReads = 0
    var ticketReads = 0
    var sleeps = 0
    var valid = true
    var catalogBody = ReconnectRequestFixture.catalog()
    var catalogAfterFirst: String?
    var catalogStatus = 200
    var metadataBody = ReconnectRequestFixture.metadata()
    var metadataStatus = 200
    var pendingReadsPerCatalog = 0
    var pendingReads = 0
    var ticketBody: String?
    var ticketMIME = "application/x-virt-viewer"
    var invalidateAfterTicket = false
    var invalidateDuringSleep = false

    func profile() async throws -> ConnectionProfile {
        try await RavadaReconnectRequest.profile(machineID: 42,
            request: { try await self.request($0) },
            validate: { guard self.valid else { throw RavadaBrokerError.cancelled } },
            sleep: {
                self.sleeps += 1
                if self.invalidateDuringSleep { self.valid = false }
                await Task.yield()
            })
    }

    private func request(_ route: RavadaBrokerRequest) async throws -> RavadaBrokerResponse {
        routes.append(route)
        switch route {
        case .catalog:
            catalogReads += 1
            pendingReads = pendingReadsPerCatalog
            return json(catalogReads > 1 ? catalogAfterFirst ?? catalogBody : catalogBody, status: catalogStatus)
        case .machineInfo:
            infoReads += 1
            if pendingReads > 0 {
                pendingReads -= 1
                return json(Self.metadata(pending: "1"), status: metadataStatus)
            }
            return json(metadataBody, status: metadataStatus)
        case .connection:
            ticketReads += 1
            if invalidateAfterTicket { valid = false }
            let body = ticketBody ?? "[virt-viewer]\ntype=spice\nhost=guest.example.invalid\ntls-port=5901\npassword=synthetic-\(ticketReads)\nfullscreen=1\n"
            return .init(data: Data(body.utf8), status: 200, contentType: ticketMIME)
        case .start, .job:
            Issue.record("Reconnect must never submit Start or poll a Start job")
            throw RavadaBrokerError.portalRequired
        }
    }

    private func json(_ body: String, status: Int = 200) -> RavadaBrokerResponse {
        .init(data: Data(body.utf8), status: status, contentType: "application/json")
    }

    static func catalog(active: Int = 1, locked: String = "0") -> String {
        "[{\"id\":10,\"name\":\"Base\",\"is_base\":1,\"list_clones\":[{\"id\":42,\"name\":\"Desktop\",\"is_active\":\(active),\"is_locked\":\(locked)}]}]"
    }

    static func metadata(id: Int = 42, active: Int = 1, base: Int = 0,
                         hibernated: String = "0", pending: String = "0", displays: String? = nil) -> String {
        let displays = displays ?? #"[{"driver":"spice-tls","file_extension":"tls.vv","is_active":1,"port":5901}]"#
        return "{\"id\":\(id),\"is_active\":\(active),\"is_base\":\(base),\"is_hibernated\":\(hibernated),\"requests\":\(pending),\"hardware\":{\"display\":\(displays)}}"
    }
}
