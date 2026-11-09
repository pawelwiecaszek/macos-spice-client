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
