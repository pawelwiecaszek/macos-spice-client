// Inputs channel (spice.proto `channel InputsChannel`).

/// `SPICE_MSG_INPUTS_INIT` / `SPICE_MSG_INPUTS_KEY_MODIFIERS` (flags16).
public struct InputsModifiers: Sendable, Hashable {
    public var modifiers: KeyboardModifiers

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        modifiers = KeyboardModifiers(rawValue: try r.readU16())
    }
}

/// Client → server inputs messages.
public enum InputsClientEncoder {
    /// Encodes a PC XT (set 1) scancode the way spice-gtk's `spice_make_scancode` does.
    ///
    /// `scancode` uses the spice-gtk convention: extended keys (normally prefixed with
    /// `0xE0`) are passed as `0x100 | code`. The wire value is a uint32 holding the byte
    /// sequence in little-endian order: `code` for normal keys, `0xE0, code` for extended
    /// keys. Release sets bit `0x80` on `code`.
    /// Source: spice-gtk 0.42 src/spice-util.c `spice_make_scancode`.
    public static func wireScancode(_ scancode: UInt16, release: Bool) -> UInt32 {
        var code = UInt32(scancode) & 0x37F
        if release { code |= 0x80 }
        if code < 0x100 { return code }
        // GUINT16_SWAP_LE_BE(0xe000 | (code - 0x100)) → 0xE0 in the low byte.
        let value = UInt16(0xE000) | UInt16(truncatingIfNeeded: code - 0x100)
        return UInt32(value.byteSwapped)
    }

    public static func keyDown(scancode: UInt16) -> SpiceMessage {
        var w = ByteWriter()
        w.writeU32(wireScancode(scancode, release: false))
        return SpiceMessage(type: InputsClientMessage.keyDown.rawValue, payload: w.bytes)
    }

    public static func keyUp(scancode: UInt16) -> SpiceMessage {
        var w = ByteWriter()
        w.writeU32(wireScancode(scancode, release: true))
        return SpiceMessage(type: InputsClientMessage.keyUp.rawValue, payload: w.bytes)
    }

    public static func keyModifiers(_ modifiers: KeyboardModifiers) -> SpiceMessage {
        var w = ByteWriter()
        w.writeU16(modifiers.rawValue)
        return SpiceMessage(type: InputsClientMessage.keyModifiers.rawValue, payload: w.bytes)
    }

    /// Server mouse mode: relative motion.
    public static func mouseMotion(dx: Int32, dy: Int32, buttons: MouseButtonMask) -> SpiceMessage {
        var w = ByteWriter()
        w.writeI32(dx)
        w.writeI32(dy)
        w.writeU16(buttons.rawValue)
        return SpiceMessage(type: InputsClientMessage.mouseMotion.rawValue, payload: w.bytes)
    }

    /// Client mouse mode: absolute position in guest pixels.
    public static func mousePosition(x: UInt32, y: UInt32, buttons: MouseButtonMask, displayID: UInt8) -> SpiceMessage {
        var w = ByteWriter()
        w.writeU32(x)
        w.writeU32(y)
        w.writeU16(buttons.rawValue)
        w.writeU8(displayID)
        return SpiceMessage(type: InputsClientMessage.mousePosition.rawValue, payload: w.bytes)
    }

    public static func mousePress(_ button: MouseButton, buttons: MouseButtonMask) -> SpiceMessage {
        var w = ByteWriter()
        w.writeU8(button.rawValue)
        w.writeU16(buttons.rawValue)
        return SpiceMessage(type: InputsClientMessage.mousePress.rawValue, payload: w.bytes)
    }

    public static func mouseRelease(_ button: MouseButton, buttons: MouseButtonMask) -> SpiceMessage {
        var w = ByteWriter()
        w.writeU8(button.rawValue)
        w.writeU16(buttons.rawValue)
        return SpiceMessage(type: InputsClientMessage.mouseRelease.rawValue, payload: w.bytes)
    }
}
