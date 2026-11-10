import Foundation

/// A bounded response whose errors never retain server text or tickets.
public struct RavadaBrokerResponse: Sendable {
    public let data: Data
    public let status: Int
    public let contentType: String

    public init(data: Data, status: Int, contentType: String) {
        self.data = data; self.status = status; self.contentType = contentType
    }

    public func decode<T: Decodable & Sendable>(_ type: T.Type) throws -> T {
        try validate(mime: "application/json")
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw RavadaBrokerError.invalidResponse }
    }

    public func validate(mime: String) throws {
        guard data.count <= RavadaCatalog.maxResponseBytes else { throw RavadaBrokerError.responseTooLarge }
        let actual = contentType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch status {
        case 401: throw RavadaBrokerError.signInRequired
        case 403: throw ["text/html", "application/xhtml+xml"].contains(actual) ? RavadaBrokerError.accessDenied : .permissionDenied
        case 300..<400: throw RavadaBrokerError.redirectRejected
        case 200: break
        default: throw RavadaBrokerError.server(status: status)
        }
        if actual == "text/html" || actual == "application/xhtml+xml" { throw RavadaBrokerError.signInRequired }
        guard actual == mime else { throw RavadaBrokerError.invalidResponse }
    }
}

