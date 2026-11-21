import Foundation

/// Fixed, content-free failures from Ravada broker requests. Never contains response bodies.
public enum RavadaBrokerError: Error, Equatable, Sendable, LocalizedError {
    case invalidAddress
    case signInRequired
    case accessDenied
    case permissionDenied
    case redirectRejected
    case responseTooLarge
    case invalidResponse
    case server(status: Int)
    case unavailable
    case timedOut
    case jobFailed
    case portalRequired
    case ambiguousStart
    case ambiguousShutdown
    case shutdownUnavailable
    case ambiguousReboot
    case rebootUnavailable
    case ambiguousHibernate
    case hibernateUnavailable
    case ambiguousResume
    case resumeUnavailable
    case resumeRequired
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "The saved portal address cannot be used for broker requests."
        case .signInRequired: "Sign in through the Ravada portal, then try again."
        case .accessDenied: "Ravada did not grant access to this request. Sign in through the portal and check your account permissions."
        case .permissionDenied: "Ravada did not permit this account to perform this request. Use the portal to continue."
        case .redirectRejected: "The Ravada request was redirected. Return to the portal to sign in or check its address."
        case .responseTooLarge: "The Ravada response exceeds the client's size limit."
        case .invalidResponse: "Ravada returned an unsupported response. Use the portal to continue."
        case .server(let status): "Ravada returned HTTP \(status) while handling the request."
        case .unavailable: "The Ravada request could not be completed. Check the portal and network connection."
        case .timedOut: "The Ravada request timed out. Check the portal before trying again."
        case .jobFailed: "The desktop request did not complete successfully. Check its status in the portal."
        case .portalRequired: "Use the portal to continue with this desktop. Its state or required details could not be verified."
        case .ambiguousStart: "The start request may still be running on Ravada. Check the portal before trying again."
        case .ambiguousShutdown: "Shutdown could not be confirmed and may still continue in Ravada. Check the portal before submitting another request."
        case .shutdownUnavailable: "Shutdown is unavailable for this desktop's permissions or state. Use the portal to continue."
        case .ambiguousReboot: "Reboot could not be confirmed and may still continue in Ravada. Check the portal and guest before submitting another request."
        case .rebootUnavailable: "Reboot is unavailable for this desktop's permissions or state. Use the portal to continue."
        case .ambiguousHibernate: "Hibernation could not be confirmed and may still continue in Ravada. Check the portal before submitting another request."
        case .hibernateUnavailable: "Hibernate is unavailable for this desktop's permissions, backend or state. Use the portal to continue."
        case .ambiguousResume: "Resume could not be confirmed and may still continue in Ravada. Check the portal and guest before submitting another request."
        case .resumeUnavailable: "Resume requires a supported hibernated desktop and permission to start it. Use Connect for a stopped desktop, or check the portal."
        case .resumeRequired: "This desktop is hibernated. Use My Desktops → Actions → Resume, then connect after it is running."
        case .cancelled: "The Ravada request was cancelled."
        }
    }
}
