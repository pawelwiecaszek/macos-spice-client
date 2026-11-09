import Foundation
import WebKit

/// Portal preferences contain an address and an opaque WebKit store ID, never credentials.
enum RavadaPortalConfiguration {
    static let urlKey = "ravadaPortalURL"

    static func portalURL(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 4096,
              let parts = URLComponents(string: text),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return parts.url
    }

    static func sameOrigin(_ candidate: URL?, as portal: URL) -> Bool {
        guard let candidate else { return false }
        return candidate.scheme?.lowercased() == "https"
            && candidate.host?.lowercased() == portal.host?.lowercased()
            && (candidate.port ?? 443) == (portal.port ?? 443)
            && candidate.user == nil && candidate.password == nil
    }

    static func isConnectionFile(_ response: URLResponse, filename: String? = nil) -> Bool {
        response.mimeType?.lowercased() == "application/x-virt-viewer"
            || response.url?.pathExtension.lowercased() == "vv"
            || URL(fileURLWithPath: filename ?? response.suggestedFilename ?? "").pathExtension.lowercased() == "vv"
    }

    static func isExpectedNavigationCancellation(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain { return error.code == NSURLErrorCancelled }
        // WebKitErrors.h defines 102 as WebKitErrorFrameLoadInterruptedByPolicyChange.
        // Converting an inline .vv response to WKDownload interrupts its page load.
        // Use the domain string because the legacy exported constant is deprecated.
        return error.domain == "WebKitErrorDomain" && error.code == 102
    }

    static func shouldDisplaySignInPage(_ response: URLResponse, portalURL: URL,
                                       isMainFrame: Bool, canShowMIMEType: Bool) -> Bool {
        // Ravada's before_dispatch hook renders its login form with status 401 for
        // protected pages. Canceling that response prevents users from signing in.
        guard isMainFrame, canShowMIMEType, sameOrigin(response.url, as: portalURL),
              (response as? HTTPURLResponse)?.statusCode == 401 else { return false }
        return ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "")
    }

    @MainActor
    static func websiteDataStore(for portal: URL, replacing: Bool = false) -> WKWebsiteDataStore {
        // Different portal origins must not share authentication state. WebKit owns the
        // cookies in its persistent store; UserDefaults only stores a random identifier.
        let origin = "\(portal.host?.lowercased() ?? ""):\(portal.port ?? 443)"
        let key = "ravadaPortalWebsiteDataStores"
        var stores = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        let id = replacing ? UUID() : (stores[origin].flatMap(UUID.init(uuidString:)) ?? UUID())
        stores[origin] = id.uuidString
        UserDefaults.standard.set(stores, forKey: key)
        return WKWebsiteDataStore(forIdentifier: id)
    }
}
