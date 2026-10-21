/// A key combination from a `.vv` file, e.g. `Ctrl+Alt+R` or `Shift+F11`.
///
/// virt-viewer accepts both `Ctrl+Alt+R` and GTK accelerator syntax (`<Ctrl><Alt>R`).
/// The key is kept as a normalized name; the app maps it to a platform key code.
public struct Hotkey: Sendable, Hashable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let alt = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        /// Super / Windows / Meta. Mapped to Command on macOS.
        public static let `super` = Modifiers(rawValue: 1 << 3)
    }

    public var modifiers: Modifiers
    /// Normalized key name: single letters/digits uppercased (`R`, `7`), function keys
    /// `F1`…`F24`, and canonical names for the rest (`Insert`, `Delete`, `Home`, `End`,
    /// `PageUp`, `PageDown`, `Escape`, `Return`, `Tab`, `Space`, `BackSpace`, `Left`,
    /// `Right`, `Up`, `Down`, `Pause`, `Print`).
    public var key: String

    public init(modifiers: Modifiers, key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.alt) { parts.append("Alt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.super) { parts.append("Super") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// Parses `Ctrl+Alt+R`, `shift+f11`, `<Control><Alt>Delete`. Returns `nil` if invalid.
    public init?(parsing text: String) {
        var modifiers: Modifiers = []
        var tokens: [Substring] = []
        var remaining = Substring(text).trimmingWhitespace()

        // GTK accelerator prefix syntax: <Mod><Mod>Key
        while remaining.hasPrefix("<"), let close = remaining.firstIndex(of: ">") {
            tokens.append(remaining[remaining.index(after: remaining.startIndex)..<close])
            remaining = remaining[remaining.index(after: close)...]
        }
        if !remaining.isEmpty {
            tokens.append(contentsOf: remaining.split(separator: "+", omittingEmptySubsequences: false))
        }
        tokens = tokens.map { $0.trimmingWhitespace() }
        guard let last = tokens.last, !last.isEmpty else { return nil }

        for token in tokens.dropLast() {
            switch token.lowercased() {
            case "ctrl", "control", "primary": modifiers.insert(.control)
            case "alt", "mod1", "option": modifiers.insert(.alt)
            case "shift": modifiers.insert(.shift)
            case "super", "meta", "win", "cmd", "command", "hyper": modifiers.insert(.super)
            default: return nil
            }
        }
        guard let key = Self.normalizeKey(last) else { return nil }
        self.modifiers = modifiers
        self.key = key
    }

    private static let aliases: [String: String] = [
        "ins": "Insert", "insert": "Insert",
        "del": "Delete", "delete": "Delete",
        "home": "Home", "end": "End",
        "pgup": "PageUp", "pageup": "PageUp", "page_up": "PageUp", "prior": "PageUp",
        "pgdn": "PageDown", "pagedown": "PageDown", "page_down": "PageDown", "next": "PageDown",
        "esc": "Escape", "escape": "Escape",
        "enter": "Return", "return": "Return",
        "tab": "Tab", "space": "Space",
        "backspace": "BackSpace",
        "left": "Left", "right": "Right", "up": "Up", "down": "Down",
        "pause": "Pause", "break": "Pause",
        "print": "Print", "sysrq": "Print",
    ]

    private static func normalizeKey(_ token: Substring) -> String? {
        let lower = token.lowercased()
        if let alias = aliases[lower] { return alias }
        if lower.count == 1, let char = lower.first, char.isLetter || char.isNumber {
            return lower.uppercased()
        }
        if lower.hasPrefix("f"), let number = Int(lower.dropFirst()), (1...24).contains(number) {
            return "F\(number)"
        }
        return nil
    }
}
