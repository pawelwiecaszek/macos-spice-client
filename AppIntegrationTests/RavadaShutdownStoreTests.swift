import Foundation
import SpiceKit
import Testing
@testable import SpiceClient

@MainActor
// Share the existing serialized suite: hide/unhide tests broadcast app-wide notifications.
extension RavadaDesktopStoreTests {
    @Test func rebootRequiresItsOwnConfirmationAndNeverSubmitsAnotherAction() async throws {
        let f = Fixture(), store = try await ready(f)
        let row = try #require(store.rows.first)
        store.preparePowerAction(row, action: .reboot)
        store.preparePowerAction(row, action: .shutdown)
        let confirmation = try await prepared(store)
        #expect(confirmation.action == .reboot && f.reboots == 0 && f.shutdowns == 0)
        store.connect(row)
        store.confirmPowerAction(confirmation.id); store.confirmPowerAction(confirmation.id)
        try await wait { !store.isBusy }
        #expect(f.reboots == 1 && f.shutdowns == 0 && f.starts == 0 && f.opens == 0)
        #expect(f.stoppingReads == 2 && store.rows.first?.machine.isActive == true)
        #expect(store.statusMessage == RavadaDesktopPowerAction.reboot.successMessage)
        #expect(store.errorMessage == nil)
        store.deactivate()
    }

    @Test func rebootCannotInheritShutdownPermissionOrUnknownMetadata() async throws {
        for permission in [0, NSNull(), "future"] as [Any] {
            let f = Fixture(); f.rebootPermission = permission
            let store = try await ready(f)
            store.preparePowerAction(try #require(store.rows.first), action: .reboot)
            try await wait { !store.isBusy }
            #expect(f.reboots == 0 && f.shutdowns == 0 && store.powerConfirmation == nil)
            #expect(store.errorMessage != nil)
            store.deactivate()
        }
    }

    @Test func rebootRevalidatesPermissionContextAndStateAfterConfirmation() async throws {
        for change in 0..<6 {
            let f = Fixture(), store = try await ready(f)
            store.preparePowerAction(try #require(store.rows.first), action: .reboot)
            let confirmation = try await prepared(store)
            switch change {
            case 0: f.rebootPermission = 0
            case 1: f.validContext = false
            case 2: f.catalogAllowed = false
            case 3: f.volatile = 1
            case 4: f.hibernated = true
            default: f.active = false
            }
            store.confirmPowerAction(confirmation.id)
            try await wait { !store.isBusy }
            #expect(f.reboots == 0 && f.shutdowns == 0 && store.statusMessage == nil)
            #expect(store.errorMessage != nil)
            store.deactivate()
        }
    }

    @Test func cancelledRebootTokenCannotConfirmReplacementShutdown() async throws {
        let f = Fixture(), store = try await ready(f)
        let row = try #require(store.rows.first)
        store.preparePowerAction(row, action: .reboot)
        let old = try await prepared(store)
        store.cancelPowerConfirmation()
        store.preparePowerAction(row, action: .shutdown)
        let replacement = try await prepared(store)
        store.confirmPowerAction(old.id)
        #expect(store.powerConfirmation?.action == .shutdown && f.reboots == 0 && f.shutdowns == 0)
        store.confirmPowerAction(replacement.id)
        try await wait { !store.isBusy }
        #expect(f.shutdowns == 1 && f.reboots == 0 && store.rows.first?.machine.isActive == false)
        store.deactivate()
    }

    @Test func ambiguousFailedOrIncompleteRebootNeverRetriesOrReportsSuccess() async throws {
        for change in 0..<5 {
            let f = Fixture(), store = try await ready(f)
            store.preparePowerAction(try #require(store.rows.first), action: .reboot)
            let confirmation = try await prepared(store)
            switch change {
            case 0: f.ambiguous = true
            case 1: f.receipt = [:]
            case 2: f.jobDomain = 43
            case 3: f.neverStops = true
            default: f.denySubmission = true
            }
            store.confirmPowerAction(confirmation.id)
            try await wait { !store.isBusy }
            #expect(f.reboots == 1 && f.shutdowns == 0 && store.statusMessage == nil)
            #expect(store.errorMessage == (change == 4 ? RavadaBrokerError.permissionDenied : .ambiguousReboot).localizedDescription)
            if change == 3 { #expect(f.stoppingReads == 180) }
            store.deactivate()
        }
    }

    @Test func cancellingSubmittedRebootPreservesItsWarningAndDiscardsLateJob() async throws {
        let f = Fixture(), store = try await ready(f)
        f.holdJob = true
        store.preparePowerAction(try #require(store.rows.first), action: .reboot)
        let confirmation = try await prepared(store)
        store.confirmPowerAction(confirmation.id)
        try await wait { f.jobWaiter != nil }
        store.cancel()
        #expect(store.errorMessage == RavadaDesktopPowerAction.reboot.cancellationMessage)
        store.confirmPowerAction(confirmation.id)
        f.jobWaiter?.resume(); f.jobWaiter = nil
        for _ in 0..<30 { await Task.yield() }
        #expect(f.reboots == 1 && f.shutdowns == 0 && f.stoppingReads == 0)
        #expect(store.statusMessage == nil && !store.isBusy)
        #expect(store.errorMessage == RavadaDesktopPowerAction.reboot.cancellationMessage)
        store.deactivate()
    }

    @Test func confirmationIsRequiredAndDuplicateActionsNeverSendTwice() async throws {
        let f = Fixture(), store = try await ready(f)
        let row = try #require(store.rows.first)
        store.preparePowerAction(row, action: .shutdown); store.preparePowerAction(row, action: .shutdown)
        let confirmation = try await prepared(store)
        #expect(f.shutdowns == 0 && store.isBusy)
        store.connect(row)
        store.confirmPowerAction(confirmation.id); store.confirmPowerAction(confirmation.id)
        try await wait { !store.isBusy }
        #expect(f.shutdowns == 1 && f.opens == 0 && f.starts == 0)
        #expect(f.stoppingReads == 2, "A successful job alone must not mean the guest stopped")
        #expect(store.rows.first?.machine.isActive == false)
        #expect(store.statusMessage != nil && store.errorMessage == nil)
        store.deactivate()
    }

    @Test func cancellingOrReusingConfirmationCannotSubmitShutdown() async throws {
        let f = Fixture(), store = try await ready(f)
        store.preparePowerAction(try #require(store.rows.first), action: .shutdown)
        let old = try await prepared(store)
        store.cancelPowerConfirmation()
        store.confirmPowerAction(old.id)
        #expect(f.shutdowns == 0 && !store.isBusy)
        store.preparePowerAction(try #require(store.rows.first), action: .shutdown)
        let replacement = try await prepared(store)
        store.confirmPowerAction(old.id)
        #expect(store.powerConfirmation?.id == replacement.id && f.shutdowns == 0)
        store.deactivate()
        store.confirmPowerAction(replacement.id)
        #expect(f.shutdowns == 0)
    }

    @Test func catalogConvenienceFlagCannotAuthorizeDeniedOrUnknownMetadata() async throws {
        for permission in [0, NSNull(), "future"] as [Any] {
            let f = Fixture(); f.permission = permission
            let store = try await ready(f)
            store.preparePowerAction(try #require(store.rows.first), action: .shutdown)
            try await wait { !store.isBusy }
            #expect(store.powerConfirmation == nil && store.errorMessage != nil)
            #expect(f.shutdowns == 0)
            store.deactivate()
        }
    }

    @Test func permissionAccessAndStateAreRevalidatedAfterConfirmation() async throws {
        for change in 0..<6 {
            let f = Fixture(), store = try await ready(f)
            store.preparePowerAction(try #require(store.rows.first), action: .shutdown)
            let confirmation = try await prepared(store)
            switch change {
            case 0: f.permission = 0
            case 1: f.catalogAllowed = false
            case 2: f.volatile = 1
            case 3: f.volatile = NSNull()
            case 4: f.active = false
            default: f.validContext = false // Profile/address/login-store admission was revoked.
            }
            store.confirmPowerAction(confirmation.id)
            try await wait { !store.isBusy }
            #expect(f.shutdowns == 0 && store.statusMessage == nil && store.errorMessage != nil)
            store.deactivate()
        }
    }

    @Test func unavailableVolatileHibernatedOrBusyMachinesNeverOfferConfirmation() async throws {
        for change in 0..<4 {
            let f = Fixture()
            switch change {
            case 0: f.volatile = 1
            case 1: f.volatile = NSNull()
            case 2: f.hibernated = true
            default: f.pending = true
            }
            let store = try await ready(f)
            store.preparePowerAction(try #require(store.rows.first), action: .shutdown)
            try await wait { !store.isBusy }
            #expect(store.powerConfirmation == nil && f.shutdowns == 0)
            store.deactivate()
        }
    }

    @Test func ambiguousOrMalformedReceiptIsNeverRetried() async throws {
        for change in 0..<3 {
            let f = Fixture(), store = try await ready(f)
            store.preparePowerAction(try #require(store.rows.first), action: .shutdown)
            let confirmation = try await prepared(store)
            if change == 0 { f.ambiguous = true }
            else { f.receipt = change == 1 ? [:] : ["req": 0] }
            store.confirmPowerAction(confirmation.id)
            try await wait { !store.isBusy }
            #expect(f.shutdowns == 1 && f.jobReads == 0)
            #expect(store.errorMessage == RavadaBrokerError.ambiguousShutdown.localizedDescription)
            #expect(store.statusMessage == nil)
            store.deactivate()
        }
    }

    @Test func failedOrMismatchedJobsAndUnstoppedMachineCannotReportSuccess() async throws {
        for change in 0..<4 {
            let f = Fixture(), store = try await ready(f)
            store.preparePowerAction(try #require(store.rows.first), action: .shutdown)
            let confirmation = try await prepared(store)
            switch change {
            case 0: f.jobID = 13
            case 1: f.jobDomain = 43
            case 2: f.jobError = "synthetic failure"
            default: f.neverStops = true
            }
            store.confirmPowerAction(confirmation.id)
            try await wait { !store.isBusy }
            #expect(f.shutdowns == 1 && store.statusMessage == nil)
            #expect(store.errorMessage == RavadaBrokerError.ambiguousShutdown.localizedDescription)
            if change == 3 { #expect(f.stoppingReads == 180) }
            store.deactivate()
        }
    }

    @Test func leavingPageCancelsMonitoringWithoutReplayingOrPublishingLateResults() async throws {
        let f = Fixture(), store = try await ready(f)
        f.holdJob = true
        store.preparePowerAction(try #require(store.rows.first), action: .shutdown)
        store.confirmPowerAction(try await prepared(store).id)
        try await wait { f.jobWaiter != nil }
        store.deactivate()
        f.jobWaiter?.resume(); f.jobWaiter = nil
        for _ in 0..<30 { await Task.yield() }
        #expect(f.shutdowns == 1 && f.stoppingReads == 0)
        #expect(!store.isBusy && store.statusMessage == nil && store.errorMessage == nil)
    }

    @Test func explicitDenialAtSubmissionRemainsPermissionFailure() async throws {
        let f = Fixture(), store = try await ready(f)
        f.denySubmission = true
        store.preparePowerAction(try #require(store.rows.first), action: .shutdown)
        store.confirmPowerAction(try await prepared(store).id)
        try await wait { !store.isBusy }
        #expect(f.shutdowns == 1 && f.jobReads == 0)
        #expect(store.errorMessage == RavadaBrokerError.permissionDenied.localizedDescription)
        store.deactivate()
    }

    private func ready(_ f: Fixture) async throws -> RavadaDesktopStore {
        let store = f.store(); store.activate()
        try await wait { !store.isBusy }
        return store
    }
    private func prepared(_ store: RavadaDesktopStore) async throws -> RavadaDesktopStore.PowerConfirmation {
        try await wait { store.powerConfirmation != nil || !store.isBusy }
        return try #require(store.powerConfirmation)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<20_000 {
            if predicate() { return }
            await Task.yield()
        }
        throw RavadaBrokerError.timedOut
    }

    @MainActor private final class Fixture {
        var active = true, catalogAllowed = true, validContext = true
        var permission: Any = 1, rebootPermission: Any = 1, volatile: Any = 0
        var hibernated = false, pending = false, ambiguous = false, neverStops = false
        var denySubmission = false, holdJob = false
        var receipt: [String: Any] = ["req": 12]
        var jobID = 12, jobDomain = 42, jobError: Any = NSNull()
        var jobWaiter: CheckedContinuation<Void, Never>?
        var shutdowns = 0, reboots = 0, starts = 0, opens = 0, jobReads = 0, stoppingReads = 0
        private var submittedAction: RavadaDesktopPowerAction?
        private var jobDone = false

        func store() -> RavadaDesktopStore {
            let defaults = UserDefaults(suiteName: "RavadaShutdown-\(UUID().uuidString)")!
            let profile = RavadaPortalProfile(name: "Synthetic portal", address: "https://portal.example.invalid/vdi/")
            return RavadaDesktopStore(profile: profile, defaults: defaults,
                request: { [self] in try await request($0) }, cancel: {},
                open: { [self] _, _ in opens += 1; return true }, sleep: { await Task.yield() })
        }
        private func json(_ value: Any, status: Int = 200) throws -> RavadaBrokerResponse {
            .init(data: try JSONSerialization.data(withJSONObject: value), status: status, contentType: "application/json")
        }
        private func request(_ request: RavadaBrokerRequest) async throws -> RavadaBrokerResponse {
            guard validContext else { throw RavadaBrokerError.cancelled }
            switch request {
            case .catalog:
                if !catalogAllowed { return try json([]) }
                return try json([["id": 10, "name": "Base", "is_base": 1, "list_clones": [
                    ["id": 42, "name": "My Desktop", "is_active": active ? 1 : 0, "is_locked": 0, "can_shutdown": 1]
                ]]])
            case .machineInfo(let id):
                #expect(id == 42)
                if jobDone {
                    stoppingReads += 1
                    if submittedAction == .shutdown, stoppingReads >= 2, !neverStops { active = false }
                    if submittedAction == .reboot, neverStops { active = false }
                }
                return try json(["id": 42, "is_active": active ? 1 : 0, "is_base": 0,
                    "is_hibernated": hibernated ? 1 : 0, "is_volatile": volatile,
                    "can_shutdown": permission, "can_reboot": rebootPermission,
                    "requests": pending || (jobDone && submittedAction == .reboot && stoppingReads < 2) ? 1 : 0,
                    "hardware": ["display": []]])
            case .shutdown(let id), .reboot(let id):
                #expect(id == 42)
                let action: RavadaDesktopPowerAction = request == .shutdown(id) ? .shutdown : .reboot
                submittedAction = action
                if action == .shutdown { shutdowns += 1 } else { reboots += 1 }
                if ambiguous { throw action.uncertainOutcome }
                if denySubmission { return try json([:], status: 403) }
                return try json(receipt)
            case .job(let id):
                #expect(id == 12)
                jobReads += 1
                if holdJob { await withCheckedContinuation { jobWaiter = $0 } }
                jobDone = true
                return try json(["id": jobID, "status": "done", "error": jobError, "id_domain": jobDomain])
            case .start:
                starts += 1; throw RavadaBrokerError.portalRequired
            case .connection:
                Issue.record("Shutdown must never fetch a ticket"); throw RavadaBrokerError.portalRequired
            }
        }
    }
}
