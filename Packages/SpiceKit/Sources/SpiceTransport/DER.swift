import Foundation

/// Minimal DER reader — just enough to pull an RSA key out of a SubjectPublicKeyInfo and
/// the subject name out of an X.509 certificate. Input is untrusted; all reads are checked.
struct DERReader {
    struct Element {
        var tag: UInt8
        /// Content bytes (without tag and length).
        var content: ArraySlice<UInt8>
    }

    enum DERError: Error { case malformed }

    private let bytes: ArraySlice<UInt8>
    private var position: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.position = bytes.startIndex
    }

    var isAtEnd: Bool { position >= bytes.endIndex }

    mutating func next() throws(DERError) -> Element {
        guard position < bytes.endIndex else { throw .malformed }
        let tag = bytes[position]
        position += 1
        guard position < bytes.endIndex else { throw .malformed }
        var length = Int(bytes[position])
        position += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count >= 1, count <= 4, position + count <= bytes.endIndex else { throw .malformed }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[position])
                position += 1
            }
        }
        guard length >= 0, position + length <= bytes.endIndex else { throw .malformed }
        let content = bytes[position..<(position + length)]
        position += length
        return Element(tag: tag, content: content)
    }

    mutating func expect(tag: UInt8) throws(DERError) -> Element {
        let element = try next()
        guard element.tag == tag else { throw .malformed }
        return element
    }
}

enum DERTag {
    static let integer: UInt8 = 0x02
    static let bitString: UInt8 = 0x03
    static let objectIdentifier: UInt8 = 0x06
    static let sequence: UInt8 = 0x30
    static let set: UInt8 = 0x31
    static let utf8String: UInt8 = 0x0C
    static let printableString: UInt8 = 0x13
    static let t61String: UInt8 = 0x14
    static let ia5String: UInt8 = 0x16
    static let bmpString: UInt8 = 0x1E
    static let universalString: UInt8 = 0x1C
    static let contextSpecific0: UInt8 = 0xA0
}

/// Helpers for the RSA ticket key and certificate subjects.
public enum X509 {
    /// Extracts the PKCS#1 `RSAPublicKey` from a SubjectPublicKeyInfo DER blob, as
    /// expected by `SecKeyCreateWithData`. Returns `nil` if the input is malformed.
    public static func rsaPublicKey(fromSubjectPublicKeyInfo spki: [UInt8]) -> [UInt8]? {
        do {
            var outer = DERReader(spki[...])
            let info = try outer.expect(tag: DERTag.sequence)
            var inner = DERReader(info.content)
            _ = try inner.expect(tag: DERTag.sequence)  // AlgorithmIdentifier
            let bitString = try inner.expect(tag: DERTag.bitString)
            guard let unusedBits = bitString.content.first, unusedBits == 0 else { return nil }
            return Array(bitString.content.dropFirst())
        } catch {
            return nil
        }
    }

    /// One attribute of a distinguished name, e.g. `("CN", "pve1.example.com")`.
    public struct NameAttribute: Sendable, Hashable {
        public var type: String
        public var value: String

        public init(type: String, value: String) {
            self.type = type
            self.value = value
        }
    }

    static let shortNames: [String: String] = [
        "2.5.4.3": "CN", "2.5.4.6": "C", "2.5.4.7": "L", "2.5.4.8": "ST",
        "2.5.4.10": "O", "2.5.4.11": "OU", "2.5.4.5": "SERIALNUMBER",
        "2.5.4.9": "STREET", "0.9.2342.19200300.100.1.25": "DC",
        "0.9.2342.19200300.100.1.1": "UID", "1.2.840.113549.1.9.1": "EMAILADDRESS",
    ]

    /// Parses the subject of a DER certificate into its attributes (in order).
    public static func subject(ofCertificate der: [UInt8]) -> [NameAttribute]? {
        do {
            var top = DERReader(der[...])
            let certificate = try top.expect(tag: DERTag.sequence)
            var certReader = DERReader(certificate.content)
            let tbs = try certReader.expect(tag: DERTag.sequence)
            var fields = DERReader(tbs.content)
            var element = try fields.next()
            if element.tag == DERTag.contextSpecific0 { element = try fields.next() }  // version
            // element = serialNumber
            _ = try fields.expect(tag: DERTag.sequence)  // signature algorithm
            _ = try fields.expect(tag: DERTag.sequence)  // issuer
            _ = try fields.expect(tag: DERTag.sequence)  // validity
            let subject = try fields.expect(tag: DERTag.sequence)
            return try parseName(subject.content)
        } catch {
            return nil
        }
    }

    static func parseName(_ content: ArraySlice<UInt8>) throws(DERReader.DERError) -> [NameAttribute] {
        var attributes: [NameAttribute] = []
        var rdns = DERReader(content)
        while !rdns.isAtEnd {
            let rdn = try rdns.expect(tag: DERTag.set)
            var set = DERReader(rdn.content)
            while !set.isAtEnd {
                let pair = try set.expect(tag: DERTag.sequence)
                var pairReader = DERReader(pair.content)
                let oid = try pairReader.expect(tag: DERTag.objectIdentifier)
                let value = try pairReader.next()
                let oidString = decodeOID(oid.content)
                attributes.append(NameAttribute(
                    type: shortNames[oidString] ?? oidString,
                    value: decodeString(tag: value.tag, value.content)
                ))
            }
        }
        return attributes
    }

    static func decodeOID(_ bytes: ArraySlice<UInt8>) -> String {
        guard let first = bytes.first else { return "" }
        var parts = [Int(first) / 40, Int(first) % 40]
        var value = 0
        for byte in bytes.dropFirst() {
            value = value << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                parts.append(value)
                value = 0
            }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    static func decodeString(tag: UInt8, _ bytes: ArraySlice<UInt8>) -> String {
        switch tag {
        case DERTag.bmpString:
            var units: [UInt16] = []
            var index = bytes.startIndex
            while index + 1 < bytes.endIndex {
                units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
                index += 2
            }
            return String(decoding: units, as: UTF16.self)
        case DERTag.t61String:
            return String(bytes.map { Character(Unicode.Scalar($0)) })  // Latin-1 approximation
        default:
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// `host-subject` handling: `OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve1`.
public enum HostSubject {
    /// Splits on unescaped `,` (and `/` style is not supported). `\,` escapes a comma.
    public static func parse(_ text: String) -> [X509.NameAttribute]? {
        var attributes: [X509.NameAttribute] = []
        var current = ""
        var escaping = false
        var parts: [String] = []
        for char in text {
            if escaping {
                current.append(char)
                escaping = false
            } else if char == "\\" {
                escaping = true
            } else if char == "," {
                parts.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        parts.append(current)
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let equals = trimmed.firstIndex(of: "=") else { return nil }
            let type = trimmed[..<equals].trimmingCharacters(in: .whitespaces).uppercased()
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !type.isEmpty else { return nil }
            attributes.append(X509.NameAttribute(type: type, value: value))
        }
        return attributes.isEmpty ? nil : attributes
    }

    /// Order-insensitive comparison of RDNs (types case-insensitive, values trimmed).
    public static func matches(expected: [X509.NameAttribute], actual: [X509.NameAttribute]) -> Bool {
        func normalize(_ list: [X509.NameAttribute]) -> [String] {
            list.map { "\($0.type.uppercased())=\($0.value.trimmingCharacters(in: .whitespaces))" }.sorted()
        }
        return normalize(expected) == normalize(actual)
    }
}

/// PEM → DER for the `.vv` `ca` value (one or more certificates).
public enum PEM {
    public static func certificates(in text: String) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var collecting = false
        var base64 = ""
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "-----BEGIN CERTIFICATE-----" {
                collecting = true
                base64 = ""
            } else if line == "-----END CERTIFICATE-----" {
                if collecting, let data = Data(base64Encoded: base64) { result.append(Array(data)) }
                collecting = false
            } else if collecting {
                base64 += line
            }
        }
        return result
    }
}
