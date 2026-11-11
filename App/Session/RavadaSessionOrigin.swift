import SpiceKit
import Foundation

/// Immutable broker authority captured when a portal hands off a connection.
/// A profile UUID alone never authorizes another address or browser login epoch.
struct RavadaSessionOrigin: Equatable, Sendable {
    let profileID: UUID
    let address: String
    let websiteDataStoreID: UUID
    let machineID: Int?

    init(profile: RavadaPortalProfile, machineID: Int?) {
        profileID = profile.id
        address = profile.address
        websiteDataStoreID = profile.websiteDataStoreID
        self.machineID = machineID
    }

    var hasMachineIdentity: Bool { machineID.map { $0 > 0 } ?? false }

    func matches(_ profile: RavadaPortalProfile) -> Bool {
        profile.id == profileID && profile.address == address && profile.websiteDataStoreID == websiteDataStoreID
    }
}

/// The ticket carries its authority check through asynchronous return boundaries.
/// Invoke validation on the main actor immediately before replacing the window.
@MainActor
struct RavadaReconnectTicket {
    let profile: ConnectionProfile
    let validate: @MainActor () throws -> Void

    init(profile: ConnectionProfile, validate: @escaping @MainActor () throws -> Void = {}) {
        self.profile = profile
        self.validate = validate
    }
}
