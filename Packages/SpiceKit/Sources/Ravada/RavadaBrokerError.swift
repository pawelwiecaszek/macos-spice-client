import Foundation

/// Fixed, content-free failures from a Ravada broker read. Never contains response bodies.
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
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "The saved portal address cannot be used for broker reads."
        case .signInRequired: "Sign in through the Ravada portal, then check desktop access again."
        case .accessDenied: "Ravada did not grant catalog access. Sign in through the portal and check your account permissions."
        case .permissionDenied: "Ravada did not permit this account to read the desktop catalog."
        case .redirectRejected: "The catalog request was redirected. Return to the portal to sign in or check its address."
        case .responseTooLarge: "The desktop catalog exceeds the client's size limit."
        case .invalidResponse: "Ravada returned an unsupported desktop catalog response. Use the portal to continue."
        case .server(let status): "Ravada returned HTTP \(status) while reading the desktop catalog."
        case .unavailable: "The desktop catalog could not be reached. Check the portal and network connection."
        case .timedOut: "Reading the desktop catalog timed out."
        case .cancelled: "The desktop catalog check was cancelled."
        }
    }
}
