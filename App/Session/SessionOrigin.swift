import Foundation
import SpiceKit

/// Broker identity is session context, never a value inferred from a Ravada .vv file.
enum SessionOrigin: Equatable, Sendable {
    case manual
    case proxmox(ProxmoxVMRef)
    /// The machine ID is absent when its authenticated display route was not recognized.
    case ravada(profileID: UUID, machineID: Int?)

    /// Preserve the existing Proxmox recognition for callers without explicit context.
    static func inferred(from profile: ConnectionProfile) -> SessionOrigin {
        if let reference = ProxmoxVMRef(profile: profile) { return .proxmox(reference) }
        return .manual
    }

    var proxmoxReference: ProxmoxVMRef? {
        guard case .proxmox(let reference) = self else { return nil }
        return reference
    }
}
