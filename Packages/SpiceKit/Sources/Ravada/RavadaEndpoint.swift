import Foundation

/// Constructs only the verified ordinary-user catalog route under a saved HTTPS base path.
/// No caller-supplied action paths or query strings are accepted.
public struct RavadaEndpoint: Equatable, Sendable {
    public let portalURL: URL
    public let catalogURL: URL

    public init(portalURL: URL) throws {
        guard var parts = URLComponents(url: portalURL, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              portalURL.absoluteString.utf8.count <= 4096 else { throw RavadaBrokerError.invalidAddress }
        // A base path is a directory, not a portal action route. Refuse encoded separators,
        // dot segments and ambiguous escaping rather than normalizing to another endpoint.
        let path = parts.percentEncodedPath
        guard !path.contains("%"), !path.contains("\\"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ $0 != "." && $0 != ".." }) else { throw RavadaBrokerError.invalidAddress }
        self.portalURL = portalURL
        parts.path = (parts.path.hasSuffix("/") ? parts.path : parts.path + "/") + "list_machines_user.json"
        guard let url = parts.url else { throw RavadaBrokerError.invalidAddress }
        self.catalogURL = url
    }

    /// HTTPS origin equality includes effective port and rejects embedded credentials.
    public func contains(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == portalURL.host?.lowercased()
            && (url.port ?? 443) == (portalURL.port ?? 443) && url.user == nil && url.password == nil
    }
}
