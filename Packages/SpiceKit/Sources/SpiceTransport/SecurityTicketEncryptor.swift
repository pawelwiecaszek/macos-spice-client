#if canImport(Security)
import Foundation
import Security

/// RSA-OAEP(SHA-1) ticket encryption with Security.framework.
public struct SecurityTicketEncryptor: TicketEncryptor {
    public init() {}

    public func encrypt(_ plaintext: [UInt8], subjectPublicKeyInfo: [UInt8]) throws -> [UInt8] {
        guard let pkcs1 = X509.rsaPublicKey(fromSubjectPublicKeyInfo: subjectPublicKeyInfo) else {
            throw TransportError.encryptionFailed
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, &error) else {
            throw TransportError.encryptionFailed
        }
        // Our own plaintext copy is zeroed after use (best effort: CF may copy internally).
        var input = Data(plaintext)
        defer { input.resetBytes(in: 0..<input.count) }
        guard SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionOAEPSHA1),
              let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, input as CFData, &error)
        else {
            throw TransportError.encryptionFailed
        }
        return Array(encrypted as Data)
    }
}
#endif
