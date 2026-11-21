import Foundation
import SpiceKit
import Testing
@testable import SpiceClient

@MainActor
// Share the existing serialized suite: hide/unhide tests broadcast app-wide notifications.
extension RavadaDesktopStoreTests {
    @Test func hibernateThenExplicitResumeUseDistinctStatesAndNeverAutoConnect() async throws {
        let f = Fixture(), store = try await ready(f)
        store.preparePowerAction(try #require(store.rows.first), action: .hibernate)
        let hibernate = try await prepared(store)
        store.confirmPowerAction(hibernate.id); store.confirmPowerAction(hibernate.id)
        try await wait { !store.isBusy }
        #expect(f.hibernates == 1 && f.starts == 0 && !f.active && f.hibernated)
        #expect(store.statusMessage == RavadaDesktopPowerAction.hibernate.successMessage)
        store.connect(try #require(store.rows.first))
        try await wait { !store.isBusy }
        #expect(f.starts == 0 && f.opens == 0 && store.errorMessage == RavadaBrokerError.resumeRequired.localizedDescription)

        f.nextJob(13); f.acceptStartAsResume = true
        store.preparePowerAction(try #require(store.rows.first), action: .resume)
        let resume = try await prepared(store)
        #expect(resume.action == .resume && f.starts == 0)
        store.confirmPowerAction(resume.id); store.confirmPowerAction(resume.id)
        try await wait { !store.isBusy }
        #expect(f.starts == 1 && f.resumes == 1 && f.active && !f.hibernated)
        #expect(f.opens == 0 && f.shutdowns == 0 && f.reboots == 0 && store.errorMessage == nil)
        #expect(store.statusMessage == RavadaDesktopPowerAction.resume.successMessage)
        store.deactivate()
    }

    @Test func savedActionsRequireOwnMetadataFlagAndVerifiedBackend() async throws {
        for action in [RavadaDesktopPowerAction.hibernate, .resume] {
            for change in 0..<5 {
                let f = Fixture(), store = try await readySavedAction(f, action: action)
                switch change {
                case 0:
                    if action == .hibernate { f.hibernatePermission = 0 } else { f.startPermission = 0 }
                case 1:
                    if action == .hibernate { f.hibernatePermission = NSNull() } else { f.startPermission = NSNull() }
                case 2: f.backendType = "Void"
                case 3: f.backendType = NSNull()
                default: f.volatile = NSNull()
                }
                store.preparePowerAction(try #require(store.rows.first), action: action)
                try await wait { !store.isBusy }
                #expect(store.powerConfirmation == nil && store.errorMessage != nil)
                #expect(f.hibernates == 0 && f.starts == 0)
                store.deactivate()
            }
        }
    }

    @Test func resumeCannotColdStartAndSavedActionStateIsRevalidated() async throws {
        for change in 0..<5 {
            let f = Fixture(), store = try await readySavedAction(f, action: .resume)
            store.preparePowerAction(try #require(store.rows.first), action: .resume)
            let confirmation = try await prepared(store)
            switch change {
            case 0: f.hibernated = false
            case 1: f.active = true
            case 2: f.startPermission = 0
            case 3: f.validContext = false
            default: f.backendType = "Unknown"
            }
            store.confirmPowerAction(confirmation.id)
            try await wait { !store.isBusy }
            #expect(f.starts == 0 && f.resumes == 0 && store.statusMessage == nil)
            store.deactivate()
        }
        let f = Fixture(); f.active = false
        let store = try await ready(f)
        store.preparePowerAction(try #require(store.rows.first), action: .resume)
        try await wait { !store.isBusy }
        #expect(store.powerConfirmation == nil && f.starts == 0)
        #expect(store.errorMessage == RavadaBrokerError.resumeUnavailable.localizedDescription)
        store.deactivate()
    }

    @Test func savedActionsRejectWrongFinalStateAndBackendFailureWithoutRetry() async throws {
        for action in [RavadaDesktopPowerAction.hibernate, .resume] {
            for change in 0..<4 {
                let f = Fixture(), store = try await readySavedAction(f, action: action)
                store.preparePowerAction(try #require(store.rows.first), action: action)
                let confirmation = try await prepared(store)
                switch change {
                case 0: f.jobError = "synthetic backend grant denial"
                case 1: f.wrongHibernationResult = true
                case 2: f.ambiguous = true
                default: f.jobStatus = "removing saved image"
                }
                store.confirmPowerAction(confirmation.id)
                try await wait { !store.isBusy }
                #expect((action == .hibernate ? f.hibernates : f.starts) == 1)
                #expect(store.statusMessage == nil && store.errorMessage == action.uncertainOutcome.localizedDescription)
                if change == 1 { #expect(f.stoppingReads == 180) }
                store.deactivate()
            }
        }
    }

    @Test func savedActionCancellationAndStaleTokensCannotSendOrPublishAgain() async throws {
        for action in [RavadaDesktopPowerAction.hibernate, .resume] {
            let f = Fixture(), store = try await readySavedAction(f, action: action)
            store.preparePowerAction(try #require(store.rows.first), action: action)
            let cancelled = try await prepared(store)
            store.cancelPowerConfirmation(); store.confirmPowerAction(cancelled.id)
            #expect(f.starts == 0 && f.hibernates == 0)
            store.preparePowerAction(try #require(store.rows.first), action: action)
            let current = try await prepared(store)
            f.holdJob = true
            store.confirmPowerAction(current.id)
            try await wait { f.jobWaiter != nil }
            store.cancel()
            store.confirmPowerAction(cancelled.id); store.confirmPowerAction(current.id)
            f.jobWaiter?.resume(); f.jobWaiter = nil
            for _ in 0..<30 { await Task.yield() }
            #expect((action == .hibernate ? f.hibernates : f.starts) == 1 && f.stoppingReads == 0)
            #expect(store.statusMessage == nil && store.errorMessage == action.cancellationMessage)
            store.deactivate()
        }
    }

    @Test func backendRestrictionDoesNotChangeAcceptedShutdownOrReboot() async throws {
        for action in [RavadaDesktopPowerAction.shutdown, .reboot] {
            let f = Fixture(); f.backendType = NSNull()
            let store = try await ready(f)
            store.preparePowerAction(try #require(store.rows.first), action: action)
            #expect(try await prepared(store).action == action)
            store.cancelPowerConfirmation(); store.deactivate()
        }
    }

    private func readySavedAction(_ f: Fixture, action: RavadaDesktopPowerAction) async throws -> RavadaDesktopStore {
        if action == .resume { f.active = false; f.hibernated = true; f.acceptStartAsResume = true }
        return try await ready(f)
    }

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
        var hibernatePermission: Any = 1, startPermission: Any = 1, backendType: Any = "KVM"
        var hibernated = false, pending = false, ambiguous = false, neverStops = false
        var denySubmission = false, holdJob = false, acceptStartAsResume = false, wrongHibernationResult = false
        var receipt: [String: Any] = ["req": 12]
        var jobID = 12, jobDomain = 42, jobError: Any = NSNull()
        var jobStatus = "done"
        var jobWaiter: CheckedContinuation<Void, Never>?
        var shutdowns = 0, reboots = 0, hibernates = 0, resumes = 0, starts = 0, opens = 0, jobReads = 0, stoppingReads = 0
        private var expectedJobID = 12
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
                    if submittedAction == .hibernate, stoppingReads >= 2, !neverStops {
                        active = false; hibernated = !wrongHibernationResult
                    }
                    if submittedAction == .resume, stoppingReads >= 2, !neverStops {
                        active = true; hibernated = wrongHibernationResult
                    }
                }
                return try json(["id": 42, "is_active": active ? 1 : 0, "is_base": 0,
                    "is_hibernated": hibernated ? 1 : 0, "is_volatile": volatile,
                    "can_shutdown": permission, "can_reboot": rebootPermission,
                    "can_hibernate": hibernatePermission, "can_start": startPermission, "type": backendType,
                    "requests": pending || (jobDone && submittedAction == .reboot && stoppingReads < 2) ? 1 : 0,
                    "hardware": ["display": []]])
            case .shutdown(let id), .reboot(let id), .hibernate(let id):
                #expect(id == 42)
                let action: RavadaDesktopPowerAction
                switch request {
                case .shutdown: action = .shutdown; shutdowns += 1
                case .reboot: action = .reboot; reboots += 1
                default: action = .hibernate; hibernates += 1
                }
                return try mutationResponse(action)
            case .job(let id):
                #expect(id == expectedJobID)
                jobReads += 1
                if holdJob { await withCheckedContinuation { jobWaiter = $0 } }
                jobDone = true
                return try json(["id": jobID, "status": jobStatus, "error": jobError, "id_domain": jobDomain])
            case .start(let id):
                starts += 1
                guard acceptStartAsResume else { throw RavadaBrokerError.portalRequired }
                #expect(id == 42 && !active && hibernated, "Resume must never cold-start a stopped VM")
                resumes += 1
                return try mutationResponse(.resume)
            case .connection:
                Issue.record("Power actions must never fetch a ticket"); throw RavadaBrokerError.portalRequired
            }
        }
        func nextJob(_ id: Int) {
            expectedJobID = id; jobID = id; receipt = ["req": id]
            jobDone = false; stoppingReads = 0
        }
        private func mutationResponse(_ action: RavadaDesktopPowerAction) throws -> RavadaBrokerResponse {
            submittedAction = action
            if ambiguous { throw action == .resume ? RavadaBrokerError.ambiguousStart : action.uncertainOutcome }
            if denySubmission { return try json([:], status: 403) }
            return try json(receipt)
        }

    }
}
