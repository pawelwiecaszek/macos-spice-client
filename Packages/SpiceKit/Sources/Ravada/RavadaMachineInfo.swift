import Foundation

/// Machine metadata is optional-permission discovery: denied/unsupported responses
/// use the portal rather than making this endpoint a catalog prerequisite.
public struct RavadaMachineInfo: Decodable, Sendable {
    public let id: Int
    public let isActive: Bool?
    public let isBase: Bool?
    public let isHibernated: Bool?
    public let requests: Int?
    /// Unlike the ordinary catalog's convenience flag, info uses user.can_shutdown.
    public let canShutdown: Bool?
    public let canReboot: Bool?
    public let canHibernate: Bool?
    public let canStart: Bool?
    public let backendType: String?
    public let isVolatile: Bool?
    public let displays: [Display]

    public struct Display: Decodable, Sendable {
        public let driver: String
        public let fileExtension: String?
        public let isActive: Bool?
        public let port: Int?
        enum CodingKeys: String, CodingKey { case driver, port; case fileExtension = "file_extension", isActive = "is_active" }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            driver = try values.decode(String.self, forKey: .driver)
            fileExtension = try values.decodeIfPresent(String.self, forKey: .fileExtension)
            isActive = values.flag(.isActive)
            port = (try? values.decode(Int.self, forKey: .port)) ?? (try? values.decode(String.self, forKey: .port)).flatMap(Int.init)
        }
        public var isSupported: Bool {
            (driver == "spice-tls" && fileExtension == "tls.vv") || (driver == "spice" && fileExtension == "vv")
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, requests, hardware
        case isActive = "is_active", isBase = "is_base", isHibernated = "is_hibernated"
        case canShutdown = "can_shutdown", isVolatile = "is_volatile"
        case canReboot = "can_reboot"
        case canHibernate = "can_hibernate", canStart = "can_start", backendType = "type"
    }
    private struct Hardware: Decodable { let display: [Display] }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        isActive = values.flag(.isActive); isBase = values.flag(.isBase); isHibernated = values.flag(.isHibernated)
        requests = try values.decodeIfPresent(Int.self, forKey: .requests)
        canShutdown = values.flag(.canShutdown); isVolatile = values.flag(.isVolatile)
        canReboot = values.flag(.canReboot)
        canHibernate = values.flag(.canHibernate); canStart = values.flag(.canStart)
        backendType = (try? values.decode(String.self, forKey: .backendType)).flatMap { $0.utf8.count <= 32 ? $0 : nil }
        displays = try values.decode(Hardware.self, forKey: .hardware).display
        guard id > 0, displays.count <= 32 else { throw RavadaBrokerError.invalidResponse }
    }

    /// Prefer advertised TLS. A pending TLS display is never downgraded to plain.
    public var preferredDisplay: Display? {
        let tls = displays.filter { $0.driver == "spice-tls" }
        if !tls.isEmpty { return tls.first(where: \.isSupported) }
        return displays.first(where: \.isSupported)
    }
}
