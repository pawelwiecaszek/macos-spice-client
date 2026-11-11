import Foundation

/// A server-authorized machine identity. Flags are optional: unknown/missing policy
/// is not permission, and unknown states must not be interpreted as stopped/running.
public struct RavadaMachine: Decodable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let alias: String?
    public let isActive: Bool?
    public let isLocked: Bool?
    public let canHibernate: Bool?
    public let canShutdown: Bool?
    public let canRemove: Bool?
    public let rawState: String?

    enum CodingKeys: String, CodingKey {
        case id, name, alias, status
        case isActive = "is_active", isLocked = "is_locked"
        case canHibernate = "can_hibernate", canShutdown = "can_shutdown", canRemove = "can_remove"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        alias = try values.decodeIfPresent(String.self, forKey: .alias)
        rawState = try values.decodeIfPresent(String.self, forKey: .status)
        guard id > 0, name.isSafeBrokerText, !name.isEmpty,
              alias.map(\.isSafeBrokerText) ?? true, rawState.map(\.isSafeBrokerText) ?? true else {
            throw RavadaBrokerError.invalidResponse
        }
        isActive = values.flag(.isActive)
        isLocked = values.flag(.isLocked)
        canHibernate = values.flag(.canHibernate)
        canShutdown = values.flag(.canShutdown)
        canRemove = values.flag(.canRemove)
    }
}

/// A catalog base and its authorized clones, or an owned standalone machine.
/// The base's nullable id_clone is not used as a clone identity.
public struct RavadaCatalogEntry: Decodable, Equatable, Identifiable, Sendable {
    public var id: Int { machine.id }
    public let machine: RavadaMachine
    public let isBase: Bool?
    public let clones: [RavadaMachine]

    enum CodingKeys: String, CodingKey { case isBase = "is_base", clones = "list_clones" }

    public init(from decoder: any Decoder) throws {
        machine = try RavadaMachine(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isBase = values.flag(.isBase)
        clones = try values.decodeIfPresent([RavadaMachine].self, forKey: .clones) ?? []
        guard clones.count <= RavadaCatalog.maxMachines,
              Set(clones.map(\.id)).count == clones.count else { throw RavadaBrokerError.invalidResponse }
    }
}

/// Bounded Ravada 2.4.6 ordinary-user catalog. No machine mutations are exposed.
/// Contract: UPC/ravada@9e1dd6b, lib/Ravada/Front.pm:135–237.
public struct RavadaCatalog: Equatable, Sendable {
    public static let maxResponseBytes = 1024 * 1024
    public static let maxMachines = 4096
    public let entries: [RavadaCatalogEntry]

    /// Decode only a successful JSON catalog. Error bodies are never exposed/logged.
    public static func decode(_ data: Data, status: Int, contentType: String) throws -> Self {
        guard data.count <= maxResponseBytes else { throw RavadaBrokerError.responseTooLarge }
        let mime = contentType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch status {
        case 401: throw RavadaBrokerError.signInRequired
        // Ravada 2.4.6 can render login/access-denied HTML as 403. Do not claim
        // an account permission denial when the response is actually a login page.
        case 403: throw ["text/html", "application/xhtml+xml"].contains(mime) ? RavadaBrokerError.accessDenied : .permissionDenied
        case 300..<400: throw RavadaBrokerError.redirectRejected
        case 200: break
        default: throw RavadaBrokerError.server(status: status)
        }
        let prefix = String(decoding: data.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if mime == "text/html" || mime == "application/xhtml+xml" || prefix.hasPrefix("<") {
            throw RavadaBrokerError.signInRequired
        }
        guard mime == "application/json" else { throw RavadaBrokerError.invalidResponse }
        do {
            let entries = try JSONDecoder().decode([RavadaCatalogEntry].self, from: data)
            guard entries.count <= maxMachines,
                  Set(entries.map(\.id)).count == entries.count,
                  entries.reduce(0, { $0 + 1 + $1.clones.count }) <= maxMachines else {
                throw RavadaBrokerError.invalidResponse
            }
            return Self(entries: entries)
        } catch { throw RavadaBrokerError.invalidResponse }
    }
}

extension KeyedDecodingContainer {
    // Perl's false can serialize as an empty string. Unknown policy stays nil.
    func flag(_ key: Key) -> Bool? {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key), value == 0 || value == 1 { return value == 1 }
        if let value = try? decode(String.self, forKey: key) {
            if value == "1" { return true }
            if value == "0" || value.isEmpty { return false }
        }
        return nil
    }
}

private extension String {
    var isSafeBrokerText: Bool {
        utf8.count <= 1024 && !unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
