import Foundation
import SpiceKit

/// Two verified actions, not an arbitrary broker command or a forced-reset interface.
enum RavadaDesktopPowerAction: CaseIterable, Hashable, Sendable {
    case shutdown
    case reboot

    var title: String {
        switch self {
        case .shutdown: String(localized: "Shut Down")
        case .reboot: String(localized: "Reboot")
        }
    }
    var confirmationTitle: String {
        switch self {
        case .shutdown: String(localized: "Shut Down Desktop?")
        case .reboot: String(localized: "Reboot Desktop?")
        }
    }
    var unavailable: RavadaBrokerError { self == .shutdown ? .shutdownUnavailable : .rebootUnavailable }
    var uncertainOutcome: RavadaBrokerError { self == .shutdown ? .ambiguousShutdown : .ambiguousReboot }
    var expectedActiveState: Bool { self == .reboot }

    func request(_ id: Int) -> RavadaBrokerRequest { self == .shutdown ? .shutdown(id) : .reboot(id) }
    func permission(_ info: RavadaMachineInfo) -> Bool? { self == .shutdown ? info.canShutdown : info.canReboot }

    var requestingMessage: String {
        switch self {
        case .shutdown: String(localized: "Requesting shutdown…")
        case .reboot: String(localized: "Requesting reboot…")
        }
    }
    var waitingMessage: String {
        switch self {
        case .shutdown: String(localized: "Waiting for the desktop to stop…")
        case .reboot: String(localized: "Waiting for Ravada to report the desktop running…")
        }
    }
    var successMessage: String {
        switch self {
        case .shutdown: String(localized: "Ravada confirmed that the desktop is shut down.")
        case .reboot: String(localized: "Ravada completed the reboot request and reports the desktop running. Verify the restart in the guest.")
        }
    }
    var cancellationMessage: String {
        switch self {
        case .shutdown: String(localized: "Shutdown monitoring cancelled. A submitted shutdown may still continue in Ravada; check the portal before trying again.")
        case .reboot: String(localized: "Reboot monitoring cancelled. A submitted reboot may still continue in Ravada; check the portal and guest before trying again.")
        }
    }
    func confirmationMessage(name: String, machineID: Int, profileName: String) -> String {
        switch self {
        case .shutdown:
            String(localized: "Shut down “\(name)” (machine \(machineID)) in \(profileName)? Save your work first. Connected viewers will disconnect. Ravada may force power off after its configured timeout. Cancelling monitoring after submission does not cancel the server request.")
        case .reboot:
            String(localized: "Reboot “\(name)” (machine \(machineID)) in \(profileName)? Save your work first. The restart interrupts guest work and may disconnect viewers. Cancelling monitoring after submission does not cancel the server request.")
        }
    }
}
