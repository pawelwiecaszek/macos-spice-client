import AppKit
import SpiceKit

/// Actions bound to hotkeys (from the `.vv` file, with defaults).
enum HotkeyAction: CaseIterable {
    case toggleFullscreen
    case releaseCursor
    case secureAttention
}

/// Matches key-down events against the session's hotkeys.
struct HotkeyMatcher {
    private struct Binding {
        var keyCode: UInt16
        var modifiers: NSEvent.ModifierFlags
        var action: HotkeyAction
    }

    private var bindings: [Binding] = []

    /// Defaults match virt-viewer: Shift+F11, Ctrl+Alt+R, Ctrl+Alt+End (Ctrl+Alt+Del is
    /// sent from the menu since macOS reserves the real combination).
    init(profile: ConnectionProfile?) {
        let pairs: [(Hotkey?, Hotkey, HotkeyAction)] = [
            (profile?.toggleFullscreenHotkey, Hotkey(modifiers: [.shift], key: "F11"), .toggleFullscreen),
            (profile?.releaseCursorHotkey, Hotkey(modifiers: [.control, .alt], key: "R"), .releaseCursor),
            (profile?.secureAttentionHotkey, Hotkey(modifiers: [.control, .alt], key: "End"), .secureAttention),
        ]
        for (configured, fallback, action) in pairs {
            let hotkey = configured ?? fallback
            guard let keyCode = Keymap.keyCode(forHotkeyName: hotkey.key) else { continue }
            bindings.append(Binding(keyCode: keyCode, modifiers: Self.flags(for: hotkey.modifiers), action: action))
        }
    }

    static func flags(for modifiers: Hotkey.Modifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.alt) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.super) { flags.insert(.command) }
        return flags
    }

    func action(for event: NSEvent) -> HotkeyAction? {
        let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let pressed = event.modifierFlags.intersection(relevant)
        return bindings.first { $0.keyCode == event.keyCode && $0.modifiers == pressed }?.action
    }

    /// Human-readable shortcut for menus, e.g. "⌃⌥R".
    func displayString(for action: HotkeyAction, profile: ConnectionProfile?) -> String? {
        let hotkey: Hotkey? = switch action {
        case .toggleFullscreen: profile?.toggleFullscreenHotkey ?? Hotkey(modifiers: [.shift], key: "F11")
        case .releaseCursor: profile?.releaseCursorHotkey ?? Hotkey(modifiers: [.control, .alt], key: "R")
        case .secureAttention: profile?.secureAttentionHotkey ?? Hotkey(modifiers: [.control, .alt], key: "End")
        }
        guard let hotkey else { return nil }
        var text = ""
        if hotkey.modifiers.contains(.control) { text += "⌃" }
        if hotkey.modifiers.contains(.alt) { text += "⌥" }
        if hotkey.modifiers.contains(.shift) { text += "⇧" }
        if hotkey.modifiers.contains(.super) { text += "⌘" }
        return text + hotkey.key
    }
}
