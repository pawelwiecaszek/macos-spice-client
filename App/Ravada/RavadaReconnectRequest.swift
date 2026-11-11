import Foundation
import SpiceKit

/// An explicit reconnect reads existing state and a fresh display ticket only. It
/// never starts, resumes or clones a desktop, even when its previous session ran.
@MainActor
enum RavadaReconnectRequest {
    static func profile(
        machineID: Int,
        request: @MainActor (RavadaBrokerRequest) async throws -> RavadaBrokerResponse,
        validate: @MainActor () throws -> Void,
        sleep: @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
    ) async throws -> ConnectionProfile {
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        var remainingReads = 90
        guard machineID > 0 else { throw RavadaBrokerError.portalRequired }
        try check(validate, deadline: deadline)
        try await authorize(machineID, request: request, validate: validate, deadline: deadline)
        _ = try await readyDisplay(machineID, remainingReads: &remainingReads, request: request,
                                   validate: validate, sleep: sleep, deadline: deadline)
        // Catalog reads may enqueue thumbnail work. Recheck permission, then wait
        // for that existing work again without replaying any server mutation.
        try await authorize(machineID, request: request, validate: validate, deadline: deadline)
        let display = try await readyDisplay(machineID, remainingReads: &remainingReads, request: request,
                                             validate: validate, sleep: sleep, deadline: deadline)
        guard let ext = display.fileExtension else { throw RavadaBrokerError.portalRequired }
        let response = try await read(.connection(machineID: machineID, driver: display.driver, fileExtension: ext),
                                      request: request, validate: validate, deadline: deadline)
        do {
            let profile = try await RavadaConnectionFile.profile(from: response, requiresTLS: display.driver == "spice-tls")
            try check(validate, deadline: deadline)
            return profile
        } catch {
            try check(validate, deadline: deadline)
            throw error as? RavadaBrokerError ?? .invalidResponse
        }
    }

    private static func authorize(
        _ id: Int, request: @MainActor (RavadaBrokerRequest) async throws -> RavadaBrokerResponse,
        validate: @MainActor () throws -> Void, deadline: ContinuousClock.Instant
    ) async throws {
        let response = try await read(.catalog, request: request, validate: validate, deadline: deadline)
        let catalog = try RavadaCatalog.decode(response.data, status: response.status, contentType: response.contentType)
        let rows = try RavadaDesktopRow.rows(in: catalog)
        guard rows.contains(where: { $0.id == id && !$0.portalOnly && $0.machine.isActive == true }) else {
            throw RavadaBrokerError.portalRequired
        }
        try check(validate, deadline: deadline)
    }

    private static func readyDisplay(
        _ id: Int, remainingReads: inout Int,
        request: @MainActor (RavadaBrokerRequest) async throws -> RavadaBrokerResponse,
        validate: @MainActor () throws -> Void, sleep: @MainActor () async throws -> Void,
        deadline: ContinuousClock.Instant
    ) async throws -> RavadaMachineInfo.Display {
        while remainingReads > 0 {
            remainingReads -= 1
            let response = try await read(.machineInfo(id), request: request, validate: validate, deadline: deadline)
            let info = try response.decode(RavadaMachineInfo.self)
            guard info.id == id, info.isBase == false, info.isActive == true, info.isHibernated == false,
                  let pending = info.requests, pending >= 0,
                  let display = info.preferredDisplay else { throw RavadaBrokerError.portalRequired }
            if pending == 0 {
                guard display.isActive == true, let port = display.port, (1...65535).contains(port) else {
                    throw RavadaBrokerError.portalRequired
                }
                try check(validate, deadline: deadline)
                return display
            }
            try check(validate, deadline: deadline)
            do { try await sleep() }
            catch {
                try check(validate, deadline: deadline)
                throw error as? RavadaBrokerError ?? .unavailable
            }
            try check(validate, deadline: deadline)
        }
        throw RavadaBrokerError.timedOut
    }

    private static func read(
        _ route: RavadaBrokerRequest,
        request: @MainActor (RavadaBrokerRequest) async throws -> RavadaBrokerResponse,
        validate: @MainActor () throws -> Void, deadline: ContinuousClock.Instant
    ) async throws -> RavadaBrokerResponse {
        try check(validate, deadline: deadline)
        do {
            let response = try await request(route)
            try check(validate, deadline: deadline)
            return response
        } catch {
            try check(validate, deadline: deadline)
            throw error as? RavadaBrokerError ?? .unavailable
        }
    }

    private static func check(_ validate: @MainActor () throws -> Void, deadline: ContinuousClock.Instant) throws {
        guard !Task.isCancelled else { throw RavadaBrokerError.cancelled }
        try validate()
        guard ContinuousClock.now < deadline else { throw RavadaBrokerError.timedOut }
    }
}

/// Shared validation for native Connect and reconnect. Tickets stay in memory and
/// parsing runs off the main actor; the caller must validate its operation after await.
enum RavadaConnectionFile {
    static func preservesEncryption(from previous: ConnectionProfile, to next: ConnectionProfile) -> Bool {
        switch (previous.plaintextExposure, next.plaintextExposure) {
        case (_, .encrypted), (.unencrypted, _): return true
        case (.partial(let before), .partial(let after)): return after.isSubset(of: before)
        default: return false
        }
    }

    static func profile(from response: RavadaBrokerResponse, requiresTLS: Bool) async throws -> ConnectionProfile {
        try response.validate(mime: "application/x-virt-viewer")
        return try await Task.detached {
            do {
                var profile = try VVFileParser.parse(Array(response.data)).profile
                if requiresTLS {
                    guard profile.tlsPort != nil, case .encrypted = profile.plaintextExposure else {
                        throw RavadaBrokerError.portalRequired
                    }
                }
                profile.fullscreen = false
                return profile
            } catch {
                throw error as? RavadaBrokerError ?? .invalidResponse
            }
        }.value
    }
}
