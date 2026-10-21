import Foundation
import USBRedirWire

/// Errors that make a `.vv` file unusable.
public enum VVFileError: Error, Equatable, Sendable, LocalizedError {
    case notUTF8
    case missingVirtViewerSection
    case unsupportedProtocol(String)
    case missingKey(String)
    case invalidValue(key: String)
    case noPort

    public var errorDescription: String? {
        switch self {
        case .notUTF8:
            "The connection file is not valid UTF-8 text."
        case .missingVirtViewerSection:
            "The connection file has no [virt-viewer] section."
        case .unsupportedProtocol(let type):
            "The connection file uses the “\(type)” protocol. Only SPICE is supported."
        case .missingKey(let key):
            "The connection file is missing the required “\(key)” entry."
        case .invalidValue(let key):
            "The connection file has an invalid value for “\(key)”."
        case .noPort:
            "The connection file specifies neither a port nor a TLS port."
        }
    }
}

/// Non-fatal issues found while parsing.
public enum VVFileWarning: Equatable, Sendable {
    case malformedLine(line: Int)
    case duplicateKey(String, line: Int)
    case keyOutsideSection(line: Int)
    case invalidOptionalValue(key: String)
    case invalidEscape(key: String)
    case unknownKey(String)
}

/// Result of parsing a `.vv` file.
public struct VVFile: Sendable {
    public var profile: ConnectionProfile
    public var warnings: [VVFileWarning]
}

/// Parser for virt-viewer connection files (GKeyFile-style INI).
///
/// Tolerates a UTF-8 BOM, CRLF line endings, `#`/`;` comments, blank lines, duplicate
/// keys (last wins), unknown keys and unknown sections.
public enum VVFileParser {
    public static func parse(_ bytes: [UInt8]) throws(VVFileError) -> VVFile {
        var slice = bytes[...]
        if slice.starts(with: [0xEF, 0xBB, 0xBF]) { slice = slice.dropFirst(3) }
        guard let text = String(validating: slice, as: UTF8.self) else { throw .notUTF8 }
        return try parse(text)
    }

    public static func parse(_ text: String) throws(VVFileError) -> VVFile {
        var warnings: [VVFileWarning] = []
        var sawVirtViewer = false
        var currentSection: Substring?
        var values: [String: (raw: Substring, line: Int)] = [:]

        var lineNumber = 0
        var body = Substring(text)
        if body.first == "\u{FEFF}" { body = body.dropFirst() }

        // "\r\n" is a single Character in Swift, so split on all three line terminators.
        let lines = body.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
        for line in lines {
            lineNumber += 1
            let trimmed = line.trimmingWhitespace()
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }

            if trimmed.hasPrefix("[") {
                guard trimmed.hasSuffix("]"), trimmed.count >= 2 else {
                    warnings.append(.malformedLine(line: lineNumber))
                    continue
                }
                let name = trimmed.dropFirst().dropLast()
                currentSection = name
                if name == "virt-viewer" { sawVirtViewer = true }
                continue
            }

            guard let equals = line.firstIndex(of: "=") else {
                warnings.append(.malformedLine(line: lineNumber))
                continue
            }
            guard let section = currentSection else {
                warnings.append(.keyOutsideSection(line: lineNumber))
                continue
            }
            guard section == "virt-viewer" else { continue }  // e.g. [ovirt]: ignored

            let key = String(line[..<equals].trimmingWhitespace())
            var value = line[line.index(after: equals)...]
            while let first = value.first, first == " " || first == "\t" { value = value.dropFirst() }
            if key.isEmpty {
                warnings.append(.malformedLine(line: lineNumber))
                continue
            }
            if values[key] != nil { warnings.append(.duplicateKey(key, line: lineNumber)) }
            values[key] = (value, lineNumber)
        }

        guard sawVirtViewer else { throw .missingVirtViewerSection }

        var reader = ValueReader(values: values)
        let profile = try reader.buildProfile()
        warnings.append(contentsOf: reader.warnings)
        return VVFile(profile: profile, warnings: warnings)
    }
}

/// Typed access to the raw key/value pairs, collecting warnings.
private struct ValueReader {
    var values: [String: (raw: Substring, line: Int)]
    var warnings: [VVFileWarning] = []
    private var consumed: Set<String> = []

    init(values: [String: (raw: Substring, line: Int)]) {
        self.values = values
    }

    mutating func string(_ key: String) -> String? {
        consumed.insert(key)
        guard let raw = values[key]?.raw else { return nil }
        let (value, ok) = Self.unescape(raw)
        if !ok { warnings.append(.invalidEscape(key: key)) }
        return value
    }

    mutating func requiredPort(_ key: String) throws(VVFileError) -> UInt16? {
        guard let text = string(key)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        guard let value = Int(text), value <= 65535 else { throw .invalidValue(key: key) }
        // Generators write port=-1 or 0 to mean "not set".
        return value > 0 ? UInt16(value) : nil
    }

    mutating func bool(_ key: String) -> Bool? {
        guard let text = string(key)?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        switch text {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default:
            warnings.append(.invalidOptionalValue(key: key))
            return nil
        }
    }

    mutating func hotkey(_ key: String) -> Hotkey? {
        guard let text = string(key), !text.isEmpty else { return nil }
        guard let hotkey = Hotkey(parsing: text) else {
            warnings.append(.invalidOptionalValue(key: key))
            return nil
        }
        return hotkey
    }

    mutating func buildProfile() throws(VVFileError) -> ConnectionProfile {
        let type = string("type")?.trimmingCharacters(in: .whitespaces)
        guard let type, !type.isEmpty else { throw .missingKey("type") }
        guard type.lowercased() == "spice" else { throw .unsupportedProtocol(type) }

        guard let host = string("host")?.trimmingCharacters(in: .whitespaces), !host.isEmpty else {
            throw .missingKey("host")
        }
        // The host ends up in DNS lookups and in HTTP CONNECT lines: no whitespace, control
        // characters or URL/HTTP delimiters (escaped "\r\n" in the file would inject headers).
        guard Self.isSafeHost(host) else { throw .invalidValue(key: "host") }

        var profile = ConnectionProfile(host: host)
        profile.port = try requiredPort("port")
        profile.tlsPort = try requiredPort("tls-port")
        guard profile.port != nil || profile.tlsPort != nil else { throw .noPort }

        if let password = string("password") { profile.password = SecretTicket(password) }

        if let proxy = string("proxy")?.trimmingCharacters(in: .whitespaces), !proxy.isEmpty {
            guard let endpoint = Self.parseProxy(proxy), Self.isSafeHost(endpoint.host) else {
                throw .invalidValue(key: "proxy")
            }
            profile.proxy = endpoint
        }

        if let ca = string("ca"), !ca.isEmpty { profile.caPEM = ca }
        if let subject = string("host-subject")?.trimmingCharacters(in: .whitespaces), !subject.isEmpty {
            profile.hostSubject = subject
        }

        if let secure = string("secure-channels") {
            guard let parsed = Self.parseSecureChannels(secure) else { throw .invalidValue(key: "secure-channels") }
            profile.secureChannels = parsed
        }

        profile.title = string("title")
        profile.fullscreen = bool("fullscreen") ?? false
        profile.deleteThisFile = bool("delete-this-file") ?? false
        profile.toggleFullscreenHotkey = hotkey("toggle-fullscreen")
        profile.releaseCursorHotkey = hotkey("release-cursor")
        profile.secureAttentionHotkey = hotkey("secure-attention")

        profile.enableUSBRedirection = bool("enable-usbredir")
        profile.enableUSBAutoshare = bool("enable-usb-autoshare") ?? false
        if let filter = string("usb-filter"), !filter.isEmpty {
            do {
                profile.usbFilter = try USBFilter(parsing: filter)
            } catch {
                // A restriction we can't read must not become "allow everything":
                // turn USB redirection (and ISO mounting) off instead.
                warnings.append(.invalidOptionalValue(key: "usb-filter"))
                profile.enableUSBRedirection = false
            }
        }

        if let depth = string("color-depth") {
            if let value = Int(depth.trimmingCharacters(in: .whitespaces)) {
                profile.colorDepth = value
            } else {
                warnings.append(.invalidOptionalValue(key: "color-depth"))
            }
        }
        if let effects = string("disable-effects") {
            profile.disableEffects = effects.split(separator: ";").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        }
        profile.enableSmartcard = bool("enable-smartcard")
        profile.versions = string("versions")
        profile.newerVersionURL = string("newer-version-url")

        for key in values.keys.sorted() where !consumed.contains(key) {
            warnings.append(.unknownKey(key))
            if let value = string(key) { profile.unknownKeys[key] = value }
        }
        return profile
    }

    /// Strict: a security setting we can't fully understand must not silently become a
    /// weaker one, so unknown names or an empty list reject the whole file (`nil`).
    static func parseSecureChannels(_ text: String) -> SecureChannels? {
        var set: Set<ChannelName> = []
        var sawAll = false
        for token in text.split(whereSeparator: { $0 == ";" || $0 == "," }) {
            let name = token.trimmingCharacters(in: .whitespaces).lowercased()
            if name.isEmpty { continue }
            if name == "all" {
                sawAll = true
            } else if let channel = ChannelName(rawValue: name) {
                set.insert(channel)
            } else {
                return nil
            }
        }
        if sawAll { return .all }
        return set.isEmpty ? nil : .some(set)
    }

    /// Same character set as `HTTPConnect.isSafeTarget` (kept local: VVFile has no
    /// transport dependency).
    static func isSafeHost(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.count <= 1024 && host.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || ("0"..."9").contains(scalar) || "-._~:[]%".unicodeScalars.contains(scalar))
        }
    }

    /// Accepts `http://host:port`, `http://host` (port 3128) and bare `host:port`.
    static func parseProxy(_ text: String) -> ProxyEndpoint? {
        var rest = Substring(text)
        if let schemeEnd = rest.range(of: "://") {
            guard rest[..<schemeEnd.lowerBound].lowercased() == "http" else { return nil }
            rest = rest[schemeEnd.upperBound...]
        }
        if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }  // drop userinfo
        guard !rest.isEmpty else { return nil }

        var host = rest
        var port: UInt16 = 3128
        if rest.hasPrefix("[") {  // [IPv6]:port
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = rest[rest.index(after: rest.startIndex)..<close]
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") {
                guard let value = UInt16(after.dropFirst()), value > 0 else { return nil }
                port = value
            } else if !after.isEmpty {
                return nil
            }
        } else if let colon = rest.lastIndex(of: ":") {
            host = rest[..<colon]
            guard let value = UInt16(rest[rest.index(after: colon)...]), value > 0 else { return nil }
            port = value
        }
        guard !host.isEmpty else { return nil }
        return ProxyEndpoint(host: String(host), port: port)
    }

    /// GKeyFile escapes: `\s` `\n` `\t` `\r` `\\`. Unknown escapes are kept literally.
    static func unescape(_ raw: Substring) -> (String, Bool) {
        guard raw.contains("\\") else { return (String(raw), true) }
        var result = ""
        result.reserveCapacity(raw.count)
        var ok = true
        var iterator = raw.makeIterator()
        while let char = iterator.next() {
            guard char == "\\" else {
                result.append(char)
                continue
            }
            switch iterator.next() {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "s": result.append(" ")
            case "\\": result.append("\\")
            case .some(let other):
                ok = false
                result.append("\\")
                result.append(other)
            case .none:
                ok = false
                result.append("\\")
            }
        }
        return (result, ok)
    }
}

extension Substring {
    func trimmingWhitespace() -> Substring {
        var slice = self
        while let first = slice.first, first.isWhitespace { slice = slice.dropFirst() }
        while let last = slice.last, last.isWhitespace { slice = slice.dropLast() }
        return slice
    }
}

/// Test hooks for file-private helpers.
enum VVFileTesting {
    static func unescape(_ text: String) -> (String, Bool) { ValueReader.unescape(Substring(text)) }
    static func parseProxy(_ text: String) -> ProxyEndpoint? { ValueReader.parseProxy(text) }
}
