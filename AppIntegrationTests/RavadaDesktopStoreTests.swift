import AppKit
import Foundation
import SpiceKit
import Testing
@testable import SpiceClient

@MainActor
@Suite(.serialized)
struct RavadaDesktopStoreTests {
    @Test func runningDesktopConnectsOnceWithoutStartAndUsesWindowedProfile() async throws {
        let fixture = DesktopFixture(active: true)
        let store = fixture.store()
        store.activate(); try await idle(store)
        let row = try #require(store.rows.first)
        store.connect(row); store.connect(row)
        try await idle(store)
        #expect(fixture.starts == 0)
        #expect(fixture.opened == [42])
        #expect(fixture.fullscreen == false)
    }

    @Test func stoppedDesktopWaitsForSuccessfulMatchingJobAndReadyDisplay() async throws {
        let fixture = DesktopFixture(active: false)
        let store = fixture.store()
        store.activate(); try await idle(store)
        store.connect(try #require(store.rows.first)); try await idle(store)
        #expect(fixture.starts == 1)
        #expect(fixture.jobReads == 2)
        #expect(fixture.opened == [42])
    }

    @Test func failedOrMismatchedJobNeverFetchesTicketOrOpensWindow() async throws {
        let fixture = DesktopFixture(active: false)
        fixture.wrongJobMachine = true
        let store = fixture.store()
        store.activate(); try await idle(store)
        store.connect(try #require(store.rows.first)); try await idle(store)
        #expect(fixture.starts == 1)
        #expect(fixture.connectionReads == 0)
        #expect(fixture.opened.isEmpty)
        #expect(store.errorMessage != nil)
    }

    @Test func ambiguousStartIsNotRetried() async throws {
        let fixture = DesktopFixture(active: false)
        fixture.ambiguousStart = true
        let store = fixture.store()
        store.activate(); try await idle(store)
        store.connect(try #require(store.rows.first)); try await idle(store)
        #expect(fixture.starts == 1)
        #expect(fixture.jobReads == 0)
        #expect(fixture.opened.isEmpty)
        #expect(store.errorMessage == RavadaBrokerError.ambiguousStart.localizedDescription)
    }

    @Test func accessChangingBeforeConnectNeverStartsAnUnauthorizedMachine() async throws {
        let fixture = DesktopFixture(active: false)
        let store = fixture.store()
        store.activate(); try await idle(store)
        let row = try #require(store.rows.first)
        fixture.denied = true
        store.connect(row); try await idle(store)
        #expect(fixture.starts == 0)
        #expect(fixture.opened.isEmpty)
    }

    @Test func leavingPageCancelsPendingJobAndSuppressesLateOpen() async throws {
        let fixture = DesktopFixture(active: false)
        fixture.blockJobs = true
        let store = fixture.store()
        store.activate(); try await idle(store)
        store.connect(try #require(store.rows.first))
        while fixture.jobContinuation == nil { await Task.yield() }
        store.deactivate()
        fixture.resumeJob()
        for _ in 0..<20 { await Task.yield() }
        #expect(!store.isBusy)
        #expect(fixture.opened.isEmpty)
        #expect(fixture.connectionReads == 0)
    }

    @Test func pendingJobTimesOutWithoutRetryingStart() async throws {
        let fixture = DesktopFixture(active: false)
        fixture.neverDone = true
        let store = fixture.store()
        store.activate(); try await idle(store)
        store.connect(try #require(store.rows.first)); try await idle(store)
        #expect(fixture.starts == 1)
        #expect(fixture.jobReads == 90)
        #expect(fixture.connectionReads == 0)
        #expect(store.errorMessage == RavadaBrokerError.timedOut.localizedDescription)
    }

    @Test func permissionRevokedDuringStartPreventsTicketFetch() async throws {
        let fixture = DesktopFixture(active: false)
        fixture.revokeAfterJob = true
        let store = fixture.store()
        store.activate(); try await idle(store)
        store.connect(try #require(store.rows.first)); try await idle(store)
        #expect(fixture.starts == 1)
        #expect(fixture.opened.isEmpty)
        #expect(fixture.connectionReads == 0)
    }

    @Test func deniedMetadataUsesPortalWithoutStartingMachine() async throws {
        let fixture = DesktopFixture(active: false)
        fixture.denyMetadata = true
        let store = fixture.store()
        store.activate(); try await idle(store)
        store.connect(try #require(store.rows.first)); try await idle(store)
        #expect(fixture.starts == 0)
        #expect(fixture.opened.isEmpty)
        #expect(store.errorMessage == RavadaBrokerError.permissionDenied.localizedDescription)
    }

    @Test func malformedTLSCannotCausePlainTicketFetch() async throws {
        let fixture = DesktopFixture(active: true)
        fixture.malformedTLS = true
        let store = fixture.store()
        store.activate(); try await idle(store)
        store.connect(try #require(store.rows.first)); try await idle(store)
        #expect(fixture.starts == 0)
        #expect(fixture.connectionReads == 0)
        #expect(fixture.opened.isEmpty)
    }

    @Test func malformedStartReceiptReportsAmbiguousOutcomeWithoutRetry() async throws {
        let fixture = DesktopFixture(active: false)
        fixture.malformedReceipt = true
        let store = fixture.store()
        store.activate(); try await idle(store)
        store.connect(try #require(store.rows.first)); try await idle(store)
        #expect(fixture.starts == 1)
        #expect(fixture.opened.isEmpty)
        #expect(store.errorMessage == RavadaBrokerError.ambiguousStart.localizedDescription)
    }

    @Test func hidingAppCancelsConnectAndUnhideDoesNotReplayStart() async throws {
        let fixture = DesktopFixture(active: false)
        fixture.blockJobs = true
        let store = fixture.store()
        store.activate(); try await idle(store)
        store.connect(try #require(store.rows.first))
        while fixture.jobContinuation == nil { await Task.yield() }
        NotificationCenter.default.post(name: NSApplication.didHideNotification, object: NSApp)
        #expect(!store.isBusy)
        fixture.resumeJob()
        for _ in 0..<20 { await Task.yield() }
        NotificationCenter.default.post(name: NSApplication.didUnhideNotification, object: NSApp)
        try await idle(store)
        #expect(fixture.starts == 1)
        #expect(fixture.connectionReads == 0)
        #expect(fixture.opened.isEmpty)
        store.deactivate()
    }

    @Test func previewWorkQueuedByCatalogIsWaitedOutWithoutStartingAgain() async throws {
        let fixture = DesktopFixture(active: true)
        fixture.previewWork = true
        let store = fixture.store()
        store.activate(); try await idle(store)
        store.connect(try #require(store.rows.first)); try await idle(store)
        #expect(fixture.starts == 0)
        #expect(fixture.infoReads >= 4)
        #expect(fixture.opened == [42])
    }

    @Test func TLSDisplayReturningPlainConnectionFileCannotOpenSession() async throws {
        let fixture = DesktopFixture(active: true)
        fixture.plainConnectionFile = true
        let store = fixture.store()
        store.activate(); try await idle(store)
        store.connect(try #require(store.rows.first)); try await idle(store)
        #expect(fixture.connectionReads == 1)
        #expect(fixture.opened.isEmpty)
        #expect(store.errorMessage == RavadaBrokerError.portalRequired.localizedDescription)
    }

    @Test func searchFavoritesPersistAndRemainProfileScoped() async throws {
        let fixture = DesktopFixture(active: true)
        let store = fixture.store()
        store.activate(); try await idle(store)
        store.toggleFavorite(42)
        store.query = "my desktop"
        #expect(store.visibleRows.count == 1)
        store.query = "missing"
        #expect(store.visibleRows.isEmpty)
        let reopened = fixture.store()
        #expect(reopened.favoriteIDs == [42])
        var other = fixture.profile; other.id = UUID()
        let isolated = fixture.store(profile: other)
        #expect(isolated.favoriteIDs.isEmpty)
    }

    @Test func baseWithoutCloneAndUnknownLockUsePortal() throws {
        let catalog = try RavadaCatalog.decode(Data(#"[{"id":10,"name":"Template","is_base":1,"list_clones":[]},{"id":99,"name":"Unknown","is_base":0,"is_active":1}]"#.utf8), status: 200, contentType: "application/json")
        #expect(try RavadaDesktopRow.rows(in: catalog).allSatisfy(\.portalOnly))
    }

    private func idle(_ store: RavadaDesktopStore) async throws {
        for _ in 0..<5000 {
            if !store.isBusy { return }
            await Task.yield()
        }
        Issue.record("Synthetic desktop operation did not finish")
        store.cancel()
    }
}

@MainActor
private final class DesktopFixture {
    var active: Bool
    var starts = 0
    var jobReads = 0
    var connectionReads = 0
    var opened: [Int] = []
    var fullscreen: Bool?
    var wrongJobMachine = false
    var ambiguousStart = false
    var denied = false
    var blockJobs = false
    var neverDone = false
    var revokeAfterJob = false
    var denyMetadata = false
    var malformedTLS = false
    var malformedReceipt = false
    var previewWork = false
    var pendingInfoReads = 0
    var infoReads = 0
    var plainConnectionFile = false
    var jobContinuation: CheckedContinuation<Void, Never>?
    let profile = RavadaPortalProfile(name: "Synthetic Portal", address: "https://portal.example.invalid/")
    let defaults: UserDefaults
    let suite = "desktop-store-\(UUID().uuidString)"

    init(active: Bool) {
        self.active = active
        defaults = UserDefaults(suiteName: suite)!
    }
    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

    func store(profile: RavadaPortalProfile? = nil) -> RavadaDesktopStore {
        RavadaDesktopStore(profile: profile ?? self.profile, defaults: defaults,
            request: { try await self.request($0) }, cancel: {}, open: { profile, id in
                self.opened.append(id); self.fullscreen = profile.fullscreen; return true
            }, sleep: { await Task.yield() })
    }

    func resumeJob() { jobContinuation?.resume(); jobContinuation = nil }

    private func json(_ body: String) -> RavadaBrokerResponse {
        .init(data: Data(body.utf8), status: 200, contentType: "application/json")
    }

    private func request(_ request: RavadaBrokerRequest) async throws -> RavadaBrokerResponse {
        switch request {
        case .catalog:
            if previewWork && active { pendingInfoReads = 1 }
            if denied { return json("[]") }
            return json("[{\"id\":10,\"name\":\"Base\",\"is_base\":1,\"list_clones\":[{\"id\":42,\"name\":\"My Desktop\",\"is_active\":\(active ? 1 : 0),\"is_locked\":0}]}]")
        case .machineInfo:
            infoReads += 1
            let pending = pendingInfoReads > 0
            if pending { pendingInfoReads -= 1 }
            if denyMetadata { return .init(data: Data(), status: 403, contentType: "application/json") }
            if malformedTLS {
                return json(#"{"id":42,"is_active":1,"is_base":0,"is_hibernated":0,"requests":0,"hardware":{"display":[{"driver":"spice","file_extension":"vv","is_active":1,"port":5900},{"driver":"spice-tls","is_active":0}]}}"#)
            }
            return json("{\"id\":42,\"is_active\":\(active ? 1 : 0),\"is_base\":0,\"is_hibernated\":0,\"requests\":\(pending ? 1 : 0),\"hardware\":{\"display\":[{\"driver\":\"spice-tls\",\"file_extension\":\"tls.vv\",\"is_active\":\(active ? 1 : 0),\"port\":5901}]}}")
        case .start:
            starts += 1
            if ambiguousStart { throw RavadaBrokerError.ambiguousStart }
            if malformedReceipt { return json("{}") }
            return json(#"{"req":12}"#)
        case .job:
            jobReads += 1
            if blockJobs { await withCheckedContinuation { jobContinuation = $0 } }
            if jobReads >= 2 && !neverDone { active = true; if revokeAfterJob { denied = true } }
            return json("{\"id\":12,\"status\":\"\(active ? "done" : "working")\",\"error\":null,\"id_domain\":\(wrongJobMachine ? 43 : 42)}")
        case .connection:
            connectionReads += 1
            if plainConnectionFile {
                return .init(data: Data("[virt-viewer]\ntype=spice\nhost=guest.example.invalid\nport=5900\n".utf8), status: 200, contentType: "application/x-virt-viewer")
            }
            return .init(data: Data("[virt-viewer]\ntype=spice\nhost=guest.example.invalid\ntls-port=5901\nfullscreen=1\n".utf8), status: 200, contentType: "application/x-virt-viewer")
        }
    }
}
