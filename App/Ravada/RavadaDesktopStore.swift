import AppKit
import CryptoKit
import Foundation
import Observation
import SpiceKit

/// Visible-page catalog and a single explicit Connect operation. No background action
/// retries: cancelling a submitted start stops this client, not the server job.
@MainActor
@Observable
final class RavadaDesktopStore: NSObject {
    let profileName: String
    var query = ""
    var favoritesOnly = false
    private(set) var rows: [RavadaDesktopRow] = []
    private(set) var favoriteIDs: Set<Int> = []
    private(set) var isRefreshing = false
    private(set) var connectingID: Int?
    private(set) var progressMessage: String?
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false
    var isBusy: Bool { isRefreshing || connectingID != nil }
    var visibleRows: [RavadaDesktopRow] {
        rows.filter { (!favoritesOnly || favoriteIDs.contains($0.id)) &&
            (query.isEmpty || $0.name.localizedStandardContains(query) || ($0.parentName?.localizedStandardContains(query) ?? false)) }
    }

    @ObservationIgnored private let request: @MainActor (RavadaBrokerRequest) async throws -> RavadaBrokerResponse
    @ObservationIgnored private let cancelRequest: @MainActor () -> Void
    @ObservationIgnored private let open: @MainActor (ConnectionProfile, Int) -> Bool
    @ObservationIgnored private let sleep: @MainActor () async throws -> Void
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let favoriteKey: String
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var submittedStart = false
    @ObservationIgnored private var resumeAfterUnhide = false

    init(profile: RavadaPortalProfile, defaults: UserDefaults = .standard,
         request: @escaping @MainActor (RavadaBrokerRequest) async throws -> RavadaBrokerResponse,
         cancel: @escaping @MainActor () -> Void,
         open: @escaping @MainActor (ConnectionProfile, Int) -> Bool,
         sleep: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        profileName = profile.name
        self.defaults = defaults
        self.request = request; cancelRequest = cancel; self.open = open; self.sleep = sleep
        let addressHash = SHA256.hash(data: Data(profile.address.utf8)).map { String(format: "%02x", $0) }.joined()
        favoriteKey = "ravadaMachineFavorites.\(profile.id.uuidString).\(addressHash)"
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidHide), name: NSApplication.didHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidUnhide), name: NSApplication.didUnhideNotification, object: nil)
        if let data = defaults.data(forKey: favoriteKey), data.count <= 128 * 1024,
           let ids = try? JSONDecoder().decode([Int].self, from: data), ids.count <= RavadaCatalog.maxMachines,
           ids.allSatisfy({ $0 > 0 }) { favoriteIDs = Set(ids) }
    }

    func activate() {
        if NSApp.isHidden { resumeAfterUnhide = true; return }
        resumeAfterUnhide = false
        isVisible = true
        refresh()
    }
    func deactivate() { resumeAfterUnhide = false; isVisible = false; cancel(showNotice: false) }

    @objc private func applicationDidHide() {
        let wasVisible = isVisible
        deactivate()
        resumeAfterUnhide = wasVisible
    }
    @objc private func applicationDidUnhide() {
        if resumeAfterUnhide { activate() } // Refresh only; never replay a submitted Start.
    }

    func toggleFavorite(_ id: Int) {
        guard rows.contains(where: { $0.id == id }) else { return }
        if favoriteIDs.contains(id) { favoriteIDs.remove(id) }
        else if favoriteIDs.count < RavadaCatalog.maxMachines { favoriteIDs.insert(id) }
        if let data = try? JSONEncoder().encode(favoriteIDs.sorted()) { defaults.set(data, forKey: favoriteKey) }
    }

    func refresh() {
        guard isVisible, !isBusy else { return }
        let token = UUID(); generation = token
        isRefreshing = true; errorMessage = nil
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = try await catalog()
                try ensureCurrent(token)
                rows = try RavadaDesktopRow.rows(in: catalog); hasLoaded = true
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                rows = []; hasLoaded = false; errorMessage = message(error)
            }
            guard generation == token else { return }
            isRefreshing = false; work = nil
        }
    }

    func connect(_ row: RavadaDesktopRow) {
        guard isVisible, !isBusy, !row.portalOnly, rows.contains(where: { $0.id == row.id && !$0.portalOnly }) else { return }
        let token = UUID(); generation = token
        connectingID = row.id; errorMessage = nil; submittedStart = false
        progressMessage = String(localized: "Checking desktop access…")
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await connect(machineID: row.id, token: token)
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                errorMessage = message(error)
            }
            guard generation == token else { return }
            connectingID = nil; progressMessage = nil; work = nil; submittedStart = false
        }
    }

    func cancel(showNotice: Bool = true) {
        let didSubmit = submittedStart
        generation = UUID(); work?.cancel(); work = nil; cancelRequest()
        isRefreshing = false; connectingID = nil; progressMessage = nil; submittedStart = false
        if showNotice { errorMessage = didSubmit
            ? String(localized: "Connection cancelled. A submitted start may still continue in Ravada; check the portal before trying again.")
            : nil }
    }

    private func connect(machineID: Int, token: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        try await verifyCatalog(machineID, token: token)
        var info = try await idleMachineInfo(machineID, token: token, deadline: deadline)
        guard info.isHibernated == false,
              info.preferredDisplay != nil else { throw RavadaBrokerError.portalRequired }
        if info.isActive == false {
            progressMessage = String(localized: "Starting desktop…")
            try ensureCurrent(token, deadline: deadline)
            submittedStart = true
            let receipt = try await submitStart(machineID, token: token)
            var complete = false
            for _ in 0..<90 {
                try ensureCurrent(token, deadline: deadline)
                let response = try await request(.job(receipt.req))
                try ensureCurrent(token, deadline: deadline)
                let job = try response.decode(RavadaJob.self)
                if try job.isComplete(requestID: receipt.req, machineID: machineID) { complete = true; break }
                progressMessage = String(localized: "Waiting for Ravada to start the desktop…")
                try await sleep()
            }
            guard complete else { throw RavadaBrokerError.timedOut }
            var ready = false
            for _ in 0..<90 {
                try ensureCurrent(token, deadline: deadline)
                info = try await machineInfo(machineID, token: token)
                if info.isActive == true, info.requests == 0,
                   let display = info.preferredDisplay, display.isActive == true,
                   let port = display.port, (1...65535).contains(port) { ready = true; break }
                progressMessage = String(localized: "Waiting for the desktop display…")
                try await sleep()
            }
            guard ready else { throw RavadaBrokerError.timedOut }
        }
        try ensureCurrent(token, deadline: deadline)
        // Re-read server authorization immediately before consuming a connection ticket.
        try await verifyCatalog(machineID, token: token)
        info = try await idleMachineInfo(machineID, token: token, deadline: deadline)
        guard info.isActive == true, info.requests == 0, let display = info.preferredDisplay,
              display.isActive == true, let port = display.port, (1...65535).contains(port),
              let ext = display.fileExtension else { throw RavadaBrokerError.portalRequired }
        try ensureCurrent(token, deadline: deadline)
        progressMessage = String(localized: "Opening desktop connection…")
        let response = try await request(.connection(machineID: machineID, driver: display.driver, fileExtension: ext))
        try ensureCurrent(token, deadline: deadline)
        try response.validate(mime: "application/x-virt-viewer")
        let requiresTLS = display.driver == "spice-tls"
        let profile = try await Task.detached {
            var profile = try VVFileParser.parse(Array(response.data)).profile
            if requiresTLS {
                guard profile.tlsPort != nil, case .encrypted = profile.plaintextExposure else {
                    throw RavadaBrokerError.portalRequired
                }
            }
            profile.fullscreen = false
            return profile
        }.value
        try ensureCurrent(token, deadline: deadline)
        if !open(profile, machineID) { throw RavadaBrokerError.cancelled }
    }

    private func submitStart(_ machineID: Int, token: UUID) async throws -> RavadaStartReceipt {
        do {
            let response = try await request(.start(machineID)) // Exactly once; never retry a send.
            try ensureCurrent(token)
            let receipt = try response.decode(RavadaStartReceipt.self)
            guard receipt.req > 0 else { throw RavadaBrokerError.invalidResponse }
            return receipt
        } catch let error as RavadaBrokerError {
            switch error {
            case .cancelled, .signInRequired, .accessDenied, .permissionDenied: throw error
            default: throw RavadaBrokerError.ambiguousStart
            }
        } catch { throw RavadaBrokerError.ambiguousStart }
    }

    private func catalog() async throws -> RavadaCatalog {
        let response = try await request(.catalog)
        return try RavadaCatalog.decode(response.data, status: response.status, contentType: response.contentType)
    }

    private func verifyCatalog(_ id: Int, token: UUID) async throws {
        let catalog = try await catalog(); try ensureCurrent(token)
        let fresh = try RavadaDesktopRow.rows(in: catalog)
        rows = fresh
        guard fresh.contains(where: { $0.id == id && !$0.portalOnly }) else { throw RavadaBrokerError.portalRequired }
    }

    private func idleMachineInfo(_ id: Int, token: UUID, deadline: ContinuousClock.Instant) async throws -> RavadaMachineInfo {
        // Reading the ordinary catalog can itself enqueue a screenshot refresh.
        // Wait for existing work without resubmitting any server action.
        for _ in 0..<90 {
            try ensureCurrent(token, deadline: deadline)
            let info = try await machineInfo(id, token: token)
            guard let pending = info.requests, pending >= 0 else { throw RavadaBrokerError.portalRequired }
            if pending == 0 { return info }
            progressMessage = String(localized: "Waiting for existing Ravada work…")
            try await sleep()
        }
        throw RavadaBrokerError.timedOut
    }

    private func machineInfo(_ id: Int, token: UUID) async throws -> RavadaMachineInfo {
        let response = try await request(.machineInfo(id)); try ensureCurrent(token)
        let info = try response.decode(RavadaMachineInfo.self)
        guard info.id == id, info.isBase == false, info.isActive != nil else { throw RavadaBrokerError.portalRequired }
        return info
    }

    private func ensureCurrent(_ token: UUID, deadline: ContinuousClock.Instant? = nil) throws {
        guard isVisible, generation == token, !Task.isCancelled else { throw RavadaBrokerError.cancelled }
        if let deadline, ContinuousClock.now >= deadline { throw RavadaBrokerError.timedOut }
    }

    private func message(_ error: any Error) -> String {
        if let error = error as? RavadaBrokerError { return error.localizedDescription }
        return RavadaBrokerError.portalRequired.localizedDescription
    }
}
