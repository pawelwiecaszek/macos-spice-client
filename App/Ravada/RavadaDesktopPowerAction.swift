import Foundation
import SpiceKit

/// Verified actions, not an arbitrary broker command or a forced-reset interface.
enum RavadaDesktopPowerAction: CaseIterable, Hashable, Sendable {
    case shutdown
    case reboot
    case hibernate
    case resume

    var title: String {
        switch self {
        case .shutdown: String(localized: "Shut Down")
        case .reboot: String(localized: "Reboot")
        case .hibernate: String(localized: "Hibernate")
        case .resume: String(localized: "Resume")
        }
    }
    var confirmationTitle: String {
        switch self {
        case .shutdown: String(localized: "Shut Down Desktop?")
        case .reboot: String(localized: "Reboot Desktop?")
        case .hibernate: String(localized: "Hibernate Desktop?")
        case .resume: String(localized: "Resume Saved Desktop?")
        }
    }
    var accessibilityPrefix: String {
        switch self {
        case .shutdown: "shutdownRavadaDesktop"
        case .reboot: "rebootRavadaDesktop"
        case .hibernate: "hibernateRavadaDesktop"
        case .resume: "resumeRavadaDesktop"
        }
    }
    var unavailable: RavadaBrokerError {
        switch self {
        case .shutdown: .shutdownUnavailable
        case .reboot: .rebootUnavailable
        case .hibernate: .hibernateUnavailable
        case .resume: .resumeUnavailable
        }
    }
    var uncertainOutcome: RavadaBrokerError {
        switch self {
        case .shutdown: .ambiguousShutdown
        case .reboot: .ambiguousReboot
        case .hibernate: .ambiguousHibernate
        case .resume: .ambiguousResume
        }
    }
    var initialActiveState: Bool { self != .resume }
    var initialHibernatedState: Bool { self == .resume }
    var expectedActiveState: Bool { self == .reboot || self == .resume }
    var expectedHibernatedState: Bool { self == .hibernate }

    func canPrepare(_ row: RavadaDesktopRow) -> Bool { row.machine.isActive == initialActiveState }
    func supportsBackend(_ info: RavadaMachineInfo) -> Bool {
        switch self {
        case .shutdown, .reboot: true
        case .hibernate, .resume: info.backendType == "KVM"
        }
    }
    func request(_ id: Int) -> RavadaBrokerRequest {
        switch self {
        case .shutdown: .shutdown(id)
        case .reboot: .reboot(id)
        case .hibernate: .hibernate(id)
        case .resume: .start(id) // KVM managed-save restore uses Start, not paused-VM /resume.
        }
    }
    func permission(_ info: RavadaMachineInfo) -> Bool? {
        switch self {
        case .shutdown: info.canShutdown
        case .reboot: info.canReboot
        case .hibernate: info.canHibernate // Advertised availability; backend still checks its grant.
        case .resume: info.canStart
        }
    }

    var requestingMessage: String {
        switch self {
        case .shutdown: String(localized: "Requesting shutdown…")
        case .reboot: String(localized: "Requesting reboot…")
        case .hibernate: String(localized: "Requesting hibernation…")
        case .resume: String(localized: "Requesting saved-state resume…")
        }
    }
    var waitingMessage: String {
        switch self {
        case .shutdown: String(localized: "Waiting for the desktop to stop…")
        case .reboot: String(localized: "Waiting for Ravada to report the desktop running…")
        case .hibernate: String(localized: "Waiting for Ravada to report the desktop hibernated…")
        case .resume: String(localized: "Waiting for Ravada to report the desktop running…")
        }
    }
    var successMessage: String {
        switch self {
        case .shutdown: String(localized: "Ravada confirmed that the desktop is shut down.")
        case .reboot: String(localized: "Ravada completed the reboot request and reports the desktop running. Verify the restart in the guest.")
        case .hibernate: String(localized: "Ravada confirmed that the desktop is hibernated.")
        case .resume: String(localized: "Ravada completed Resume and reports the desktop running. Verify your saved state in the guest.")
        }
    }
    var cancellationMessage: String {
        switch self {
        case .shutdown: String(localized: "Shutdown monitoring cancelled. A submitted shutdown may still continue in Ravada; check the portal before trying again.")
        case .reboot: String(localized: "Reboot monitoring cancelled. A submitted reboot may still continue in Ravada; check the portal and guest before trying again.")
        case .hibernate: String(localized: "Hibernate monitoring cancelled. A submitted hibernation may still continue in Ravada; check the portal before trying again.")
        case .resume: String(localized: "Resume monitoring cancelled. A submitted resume may still continue in Ravada; check the portal and guest before trying again.")
        }
    }
    func confirmationMessage(name: String, machineID: Int, profileName: String) -> String {
        switch self {
        case .shutdown:
            String(localized: "Shut down “\(name)” (machine \(machineID)) in \(profileName)? Save your work first. Connected viewers will disconnect. Ravada may force power off after its configured timeout. Cancelling monitoring after submission does not cancel the server request.")
        case .reboot:
            String(localized: "Reboot “\(name)” (machine \(machineID)) in \(profileName)? Save your work first. The restart interrupts guest work and may disconnect viewers. Cancelling monitoring after submission does not cancel the server request.")
        case .hibernate:
            String(localized: "Hibernate “\(name)” (machine \(machineID)) in \(profileName)? Save important work first. Ravada will try to save the VM's memory and stop it, disconnecting viewers. Saved state is not a backup: if restoration fails later, Ravada may discard it and start fresh. Cancelling monitoring after submission does not cancel the server request.")
        case .resume:
            String(localized: "Resume “\(name)” (machine \(machineID)) in \(profileName)? Ravada will try to restore its saved state. If restoration fails, the server may discard saved memory and start fresh, losing unsaved guest work. Cancelling monitoring after submission does not cancel the server request.")
        }
    }
}
