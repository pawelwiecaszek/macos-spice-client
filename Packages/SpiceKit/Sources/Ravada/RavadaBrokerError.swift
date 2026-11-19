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
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "The saved portal address cannot be used for broker reads."
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
        case .portalRequired: "Use the portal to connect to this desktop. Its state or display details could not be verified."
        case .ambiguousStart: "The start request may still be running on Ravada. Check the portal before trying again."
        case .cancelled: "The Ravada request was cancelled."
        }
    }
}
