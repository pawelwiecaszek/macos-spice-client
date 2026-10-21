/// usbredir device filter, as used by the `.vv` `usb-filter` key and by auto-redirection.
///
/// Format (usbredirfilter.h): rules separated by `|`, each rule is
/// `class,vendor,product,version,allow`. `-1` is a wildcard; numbers may be
/// decimal or `0x`-prefixed hex. The first matching rule wins; a device that
/// matches no rule is denied.
public struct USBFilter: Sendable, Hashable {
    public struct Rule: Sendable, Hashable {
        /// USB class code (`nil` = any).
        public var deviceClass: UInt8?
        public var vendorID: UInt16?
        public var productID: UInt16?
        /// BCD device version (`nil` = any).
        public var deviceVersion: UInt16?
        public var allow: Bool

        public init(deviceClass: UInt8? = nil, vendorID: UInt16? = nil, productID: UInt16? = nil,
                    deviceVersion: UInt16? = nil, allow: Bool) {
            self.deviceClass = deviceClass
            self.vendorID = vendorID
            self.productID = productID
            self.deviceVersion = deviceVersion
            self.allow = allow
        }

        func matches(_ device: Device) -> Bool {
            if let deviceClass, !device.classes.contains(deviceClass) { return false }
            if let vendorID, vendorID != device.vendorID { return false }
            if let productID, productID != device.productID { return false }
            if let deviceVersion, deviceVersion != device.deviceVersion { return false }
            return true
        }
    }

    /// Minimal description of a USB device for filter evaluation.
    public struct Device: Sendable, Hashable {
        /// Device class plus every interface class (usbredir matches either).
        public var classes: Set<UInt8>
        public var vendorID: UInt16
        public var productID: UInt16
        public var deviceVersion: UInt16

        public init(classes: Set<UInt8>, vendorID: UInt16, productID: UInt16, deviceVersion: UInt16) {
            self.classes = classes
            self.vendorID = vendorID
            self.productID = productID
            self.deviceVersion = deviceVersion
        }
    }

    public enum ParseError: Error, Equatable, Sendable {
        case wrongFieldCount(rule: String)
        case invalidNumber(String)
        case outOfRange(String)
    }

    public var rules: [Rule]

    public init(rules: [Rule]) { self.rules = rules }

    /// Parses a filter string. Empty rules (e.g. a trailing `|`) are skipped.
    public init(parsing string: String) throws(ParseError) {
        var rules: [Rule] = []
        for rawRule in string.split(separator: "|", omittingEmptySubsequences: true) {
            let trimmed = rawRule.trimmingWhitespace()
            if trimmed.isEmpty { continue }
            let fields = trimmed.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingWhitespace() }
            guard fields.count == 5 else { throw .wrongFieldCount(rule: String(trimmed)) }
            let values = try fields.map { field throws(ParseError) -> Int in try Self.parseNumber(field) }
            func optional<T: FixedWidthInteger>(_ value: Int, as _: T.Type) throws(ParseError) -> T? {
                if value == -1 { return nil }
                guard let converted = T(exactly: value) else { throw .outOfRange(String(value)) }
                return converted
            }
            guard values[4] == 0 || values[4] == 1 else { throw .outOfRange(String(values[4])) }
            rules.append(Rule(
                deviceClass: try optional(values[0], as: UInt8.self),
                vendorID: try optional(values[1], as: UInt16.self),
                productID: try optional(values[2], as: UInt16.self),
                deviceVersion: try optional(values[3], as: UInt16.self),
                allow: values[4] == 1
            ))
        }
        self.rules = rules
    }

    /// Returns whether `device` is allowed: first matching rule decides, default deny.
    public func allows(_ device: Device) -> Bool {
        for rule in rules where rule.matches(device) {
            return rule.allow
        }
        return false
    }

    private static func parseNumber(_ text: Substring) throws(ParseError) -> Int {
        if text == "-1" { return -1 }
        let lower = text.lowercased()
        let value: Int?
        if lower.hasPrefix("0x") {
            value = Int(lower.dropFirst(2), radix: 16)
        } else {
            value = Int(lower, radix: 10)
        }
        guard let value, value >= 0 else { throw .invalidNumber(String(text)) }
        return value
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
