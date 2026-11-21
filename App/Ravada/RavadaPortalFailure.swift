import Foundation

/// A fixed, content-free failure description; never retains an underlying error or URL.
struct RavadaPortalFailure: Error, Equatable, Sendable {
    enum Phase: String, CaseIterable, Sendable {
        case loadingPortal, downloadingConnection, readingConnection
    }

    enum Kind: String, CaseIterable, Sendable {
        case network, timeout, certificate, signInRequired, permissionDenied, server
        case invalidConnectionFile, fileTooLarge, untrustedDownload, unsupportedAddress
        case browserStopped, storage, download
    }

    enum Recovery: Equatable, Sendable {
        case reloadPortal, signIn, chooseMachine
    }

    let kind: Kind
    let phase: Phase

    var message: String {
        switch kind {
        case .network:
            String(localized: "The portal connection was lost. Check your network connection, then reload the portal.")
        case .timeout:
            String(localized: "The portal request took too long. Reload the portal and choose the machine again.")
        case .certificate:
            String(localized: "A secure connection to the portal could not be established. Check the portal certificate and your Mac’s date and time before reloading.")
        case .signInRequired:
            String(localized: "The portal requires you to sign in. Open the portal and sign in again before choosing a machine.")
        case .permissionDenied:
            String(localized: "The portal denied access to this connection. Return to the portal and choose a machine you are allowed to use.")
        case .server:
            String(localized: "The portal could not complete the request. Try again later, or contact your Ravada administrator if the problem continues.")
        case .invalidConnectionFile:
            String(localized: "The portal did not return a valid SPICE connection file. Return to the portal and choose the machine again.")
        case .fileTooLarge:
            String(localized: "The connection file exceeded the size limit. Return to the portal and choose the machine again.")
        case .untrustedDownload:
            String(localized: "The connection download came from an unsupported location. Choose the machine from the configured Ravada portal.")
        case .unsupportedAddress:
            String(localized: "The portal tried to open an insecure or unsupported address. Reload the configured HTTPS portal to continue.")
        case .browserStopped:
            String(localized: "The portal browser stopped. Reload the portal to continue.")
        case .storage:
            String(localized: "The connection file could not be saved or read. Check available disk space, then choose the machine again.")
        case .download:
            String(localized: "The connection file could not be downloaded. Return to the portal and choose the machine again.")
        }
    }

    var recovery: Recovery {
        switch kind {
        case .signInRequired:
            .signIn
        case .permissionDenied, .invalidConnectionFile, .fileTooLarge, .untrustedDownload, .storage, .download:
            .chooseMachine
        case .network, .timeout, .certificate, .server, .unsupportedAddress, .browserStopped:
            .reloadPortal
        }
    }

    static func classify(_ error: any Error, phase: Phase) -> Self? {
        if let failure = error as? Self { return failure }
        guard !RavadaPortalConfiguration.isExpectedNavigationCancellation(error) else { return nil }
        let error = error as NSError
        let kind: Kind
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorTimedOut:
                kind = .timeout
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired:
                kind = .certificate
            case NSURLErrorUserAuthenticationRequired:
                kind = .signInRequired
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
                 NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
                kind = .network
            default:
                kind = phase == .loadingPortal ? .network : .download
            }
        } else if error.domain == NSCocoaErrorDomain {
            kind = .storage
        } else {
            kind = phase == .readingConnection ? .invalidConnectionFile
                : (phase == .loadingPortal ? .network : .download)
        }
        return Self(kind: kind, phase: phase)
    }

    /// Checks only the response metadata. The bounded connection-file parser remains
    /// responsible for checking the body; HTML never proves that login has expired.
    static func responseFailure(_ response: URLResponse, portalURL: URL, isMainFrame: Bool = true,
                                filename: String? = nil) -> Self? {
        let phase = Phase.downloadingConnection
        guard isMainFrame, RavadaPortalConfiguration.sameOrigin(response.url, as: portalURL) else {
            return Self(kind: .untrustedDownload, phase: phase)
        }
        guard let http = response as? HTTPURLResponse else {
            return Self(kind: .download, phase: phase)
        }
        switch http.statusCode {
        case 401: return Self(kind: .signInRequired, phase: phase)
        case 403: return Self(kind: .permissionDenied, phase: phase)
        case 500...599: return Self(kind: .server, phase: phase)
        case 200...299: break
        default: return Self(kind: .download, phase: phase)
        }
        guard response.expectedContentLength <= 1024 * 1024 else {
            return Self(kind: .fileTooLarge, phase: phase)
        }
        let mime = response.mimeType?.lowercased()
        guard response.expectedContentLength >= NSURLSessionTransferSizeUnknown,
              mime != "text/html", mime != "application/xhtml+xml",
              RavadaPortalConfiguration.isConnectionFile(response, filename: filename) else {
            return Self(kind: .invalidConnectionFile, phase: phase)
        }
        return nil
    }
}
