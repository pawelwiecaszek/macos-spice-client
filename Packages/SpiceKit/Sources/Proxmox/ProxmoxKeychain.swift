#if canImport(Security)
import Foundation
import Security

/// Stores Proxmox API token secrets in the user's login Keychain (one generic-password
/// item per server). Secrets never go to UserDefaults, files or logs.
public enum ProxmoxKeychain {
    static let service = "com.pawelwiecaszek.spiceclient.proxmox-token"

    public enum KeychainError: Error, Equatable, Sendable, LocalizedError {
        case status(OSStatus)
        public var errorDescription: String? {
            if case .status(let status) = self {
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                return "Keychain: \(message)"
            }
            return nil
        }
    }

    public static func save(secret: String, for server: UUID) throws(KeychainError) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: server.uuidString,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: Data(secret.utf8),
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
            kSecAttrLabel: "MacOS Spice Client – Proxmox API token",
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw .status(status) }
    }

    public static func secret(for server: UUID) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: server.uuidString,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(for server: UUID) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: server.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif
