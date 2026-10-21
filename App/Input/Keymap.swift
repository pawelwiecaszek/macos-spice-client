import AppKit
import Carbon.HIToolbox

/// macOS virtual key code (`NSEvent.keyCode`, `kVK_*`) → PC XT set-1 scancode.
///
/// Extended keys (sent with an `0xE0` prefix on a PC) are encoded as `0x100 | code`,
/// the convention `InputsClientEncoder.wireScancode` expects (same as spice-gtk).
/// Layout-independent: this maps physical key positions, so the guest's keyboard layout
/// decides which character is produced.
enum Keymap {
    static func scancode(forKeyCode keyCode: UInt16) -> UInt16? {
        // Apple ISO keyboards report § (left of 1) and the key beside left Shift swapped
        // relative to PC positions; QEMU's Cocoa UI applies the same correction.
        // TODO(verify): confirm on real ISO hardware.
        if isISOKeyboard {
            if Int(keyCode) == kVK_ISO_Section { return table[kVK_ANSI_Grave] }
            if Int(keyCode) == kVK_ANSI_Grave { return table[kVK_ISO_Section] }
        }
        return table[Int(keyCode)]
    }

    static var isISOKeyboard: Bool {
        KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO
    }

    static let table: [Int: UInt16] = [
        // Letters
        kVK_ANSI_A: 0x1E, kVK_ANSI_B: 0x30, kVK_ANSI_C: 0x2E, kVK_ANSI_D: 0x20,
        kVK_ANSI_E: 0x12, kVK_ANSI_F: 0x21, kVK_ANSI_G: 0x22, kVK_ANSI_H: 0x23,
        kVK_ANSI_I: 0x17, kVK_ANSI_J: 0x24, kVK_ANSI_K: 0x25, kVK_ANSI_L: 0x26,
        kVK_ANSI_M: 0x32, kVK_ANSI_N: 0x31, kVK_ANSI_O: 0x18, kVK_ANSI_P: 0x19,
        kVK_ANSI_Q: 0x10, kVK_ANSI_R: 0x13, kVK_ANSI_S: 0x1F, kVK_ANSI_T: 0x14,
        kVK_ANSI_U: 0x16, kVK_ANSI_V: 0x2F, kVK_ANSI_W: 0x11, kVK_ANSI_X: 0x2D,
        kVK_ANSI_Y: 0x15, kVK_ANSI_Z: 0x2C,
        // Digit row
        kVK_ANSI_1: 0x02, kVK_ANSI_2: 0x03, kVK_ANSI_3: 0x04, kVK_ANSI_4: 0x05,
        kVK_ANSI_5: 0x06, kVK_ANSI_6: 0x07, kVK_ANSI_7: 0x08, kVK_ANSI_8: 0x09,
        kVK_ANSI_9: 0x0A, kVK_ANSI_0: 0x0B, kVK_ANSI_Minus: 0x0C, kVK_ANSI_Equal: 0x0D,
        // Punctuation
        kVK_ANSI_LeftBracket: 0x1A, kVK_ANSI_RightBracket: 0x1B, kVK_ANSI_Semicolon: 0x27,
        kVK_ANSI_Quote: 0x28, kVK_ANSI_Grave: 0x29, kVK_ANSI_Backslash: 0x2B,
        kVK_ANSI_Comma: 0x33, kVK_ANSI_Period: 0x34, kVK_ANSI_Slash: 0x35,
        kVK_ISO_Section: 0x56,  // the extra ISO key (same choice as QEMU's Cocoa UI)
        // Editing / whitespace
        kVK_Escape: 0x01, kVK_Delete: 0x0E, kVK_Tab: 0x0F, kVK_Return: 0x1C, kVK_Space: 0x39,
        kVK_CapsLock: 0x3A,
        // Modifiers (Command = Windows/Super)
        kVK_Shift: 0x2A, kVK_RightShift: 0x36, kVK_Control: 0x1D, kVK_RightControl: 0x11D,
        kVK_Option: 0x38, kVK_RightOption: 0x138, kVK_Command: 0x15B, kVK_RightCommand: 0x15C,
        // Function keys
        kVK_F1: 0x3B, kVK_F2: 0x3C, kVK_F3: 0x3D, kVK_F4: 0x3E, kVK_F5: 0x3F, kVK_F6: 0x40,
        kVK_F7: 0x41, kVK_F8: 0x42, kVK_F9: 0x43, kVK_F10: 0x44, kVK_F11: 0x57, kVK_F12: 0x58,
        kVK_F13: 0x64, kVK_F14: 0x65, kVK_F15: 0x66, kVK_F16: 0x67, kVK_F17: 0x68, kVK_F18: 0x69,
        kVK_F19: 0x6A, kVK_F20: 0x6B,
        // Navigation (extended)
        kVK_Help: 0x152,  // Insert position on full-size keyboards
        kVK_ForwardDelete: 0x153, kVK_Home: 0x147, kVK_End: 0x14F,
        kVK_PageUp: 0x149, kVK_PageDown: 0x151,
        kVK_LeftArrow: 0x14B, kVK_RightArrow: 0x14D, kVK_UpArrow: 0x148, kVK_DownArrow: 0x150,
        // Keypad
        kVK_ANSI_Keypad0: 0x52, kVK_ANSI_Keypad1: 0x4F, kVK_ANSI_Keypad2: 0x50, kVK_ANSI_Keypad3: 0x51,
        kVK_ANSI_Keypad4: 0x4B, kVK_ANSI_Keypad5: 0x4C, kVK_ANSI_Keypad6: 0x4D, kVK_ANSI_Keypad7: 0x47,
        kVK_ANSI_Keypad8: 0x48, kVK_ANSI_Keypad9: 0x49, kVK_ANSI_KeypadDecimal: 0x53,
        kVK_ANSI_KeypadMultiply: 0x37, kVK_ANSI_KeypadPlus: 0x4E, kVK_ANSI_KeypadMinus: 0x4A,
        kVK_ANSI_KeypadDivide: 0x135, kVK_ANSI_KeypadEnter: 0x11C, kVK_ANSI_KeypadEquals: 0x59,
        kVK_ANSI_KeypadClear: 0x45,  // Num Lock position
        // Media
        kVK_Mute: 0x120, kVK_VolumeDown: 0x12E, kVK_VolumeUp: 0x130,
        // JIS
        kVK_JIS_Yen: 0x7D, kVK_JIS_Underscore: 0x73, kVK_JIS_KeypadComma: 0x7E,
        kVK_JIS_Eisu: 0x7B, kVK_JIS_Kana: 0x70,
    ]

    /// Scancodes for the `.vv` hotkey key names (`Hotkey.key`).
    static func keyCode(forHotkeyName name: String) -> UInt16? {
        if name.count == 1, let char = name.first {
            let letters: [Character: Int] = [
                "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D, "E": kVK_ANSI_E,
                "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H, "I": kVK_ANSI_I, "J": kVK_ANSI_J,
                "K": kVK_ANSI_K, "L": kVK_ANSI_L, "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O,
                "P": kVK_ANSI_P, "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
                "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X, "Y": kVK_ANSI_Y,
                "Z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
                "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8,
                "9": kVK_ANSI_9,
            ]
            return letters[char].map { UInt16($0) }
        }
        let named: [String: Int] = [
            "Insert": kVK_Help, "Delete": kVK_ForwardDelete, "Home": kVK_Home, "End": kVK_End,
            "PageUp": kVK_PageUp, "PageDown": kVK_PageDown, "Escape": kVK_Escape, "Return": kVK_Return,
            "Tab": kVK_Tab, "Space": kVK_Space, "BackSpace": kVK_Delete, "Left": kVK_LeftArrow,
            "Right": kVK_RightArrow, "Up": kVK_UpArrow, "Down": kVK_DownArrow,
            "F1": kVK_F1, "F2": kVK_F2, "F3": kVK_F3, "F4": kVK_F4, "F5": kVK_F5, "F6": kVK_F6,
            "F7": kVK_F7, "F8": kVK_F8, "F9": kVK_F9, "F10": kVK_F10, "F11": kVK_F11, "F12": kVK_F12,
            "F13": kVK_F13, "F14": kVK_F14, "F15": kVK_F15, "F16": kVK_F16, "F17": kVK_F17,
            "F18": kVK_F18, "F19": kVK_F19, "F20": kVK_F20,
        ]
        return named[name].map { UInt16($0) }
    }

    /// Ctrl+Alt+Del as press/release scancodes.
    static let ctrlAltDelete: [(UInt16, Bool)] = [
        (0x1D, true), (0x38, true), (0x153, true),
        (0x153, false), (0x38, false), (0x1D, false),
    ]
}
