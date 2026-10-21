import Foundation
import SpiceWire

// Clipboard messages of the vdagent protocol (spice-protocol vd_agent.h, BSD-licensed):
// VD_AGENT_CLIPBOARD_GRAB / _REQUEST / VD_AGENT_CLIPBOARD / _RELEASE.
//
// With VD_AGENT_CAP_CLIPBOARD_SELECTION negotiated, every clipboard message starts with
// a 4-byte header: selection (uint8) + 3 reserved bytes. Without it there is no header
// and only the CLIPBOARD selection exists.

/// `VD_AGENT_CLIPBOARD_*` data types.
public enum ClipboardDataType: UInt32, Sendable, CaseIterable {
    case none = 0
    case utf8Text = 1
    case png = 2
    case bmp = 3
    case tiff = 4
    case jpeg = 5
    case fileList = 6
}

/// `VD_AGENT_CLIPBOARD_SELECTION_*`. macOS only has the regular clipboard.
public enum ClipboardSelection: UInt8, Sendable {
    case clipboard = 0
    case primary = 1
    case secondary = 2
}

/// A decoded clipboard message from the guest.
public enum ClipboardMessage: Sendable, Equatable {
    case grab(selection: ClipboardSelection, types: [ClipboardDataType])
    case request(selection: ClipboardSelection, type: ClipboardDataType)
    case data(selection: ClipboardSelection, type: ClipboardDataType, bytes: [UInt8])
    case release(selection: ClipboardSelection)
}

public enum ClipboardCodec {
    /// Largest clipboard payload accepted from the guest or sent to it.
    public static let maxDataSize = 32 * 1024 * 1024

    /// Decodes a clipboard agent message; `nil` for other types or unknown selections.
    public static func decode(_ message: AgentMessage, selectionHeader: Bool) throws(WireError) -> ClipboardMessage? {
        guard let kind = message.knownType,
              [.clipboardGrab, .clipboardRequest, .clipboard, .clipboardRelease].contains(kind) else { return nil }
        var reader = ByteReader(message.data)
        var selection = ClipboardSelection.clipboard
        if selectionHeader {
            guard let parsed = ClipboardSelection(rawValue: try reader.readU8()) else { return nil }
            selection = parsed
            for _ in 0 ..< 3 { _ = try reader.readU8() }
        }
        switch kind {
        case .clipboardGrab:
            var types: [ClipboardDataType] = []
            while !reader.isAtEnd, types.count < 64 {
                if let type = ClipboardDataType(rawValue: try reader.readU32()), type != .none { types.append(type) }
            }
            return .grab(selection: selection, types: types)
        case .clipboardRequest:
            guard let type = ClipboardDataType(rawValue: try reader.readU32()) else { return nil }
            return .request(selection: selection, type: type)
        case .clipboard:
            guard let type = ClipboardDataType(rawValue: try reader.readU32()) else { return nil }
            guard reader.remaining <= maxDataSize else { throw .limitExceeded("clipboard \(reader.remaining)") }
            return .data(selection: selection, type: type, bytes: Array(message.data[reader.offset...]))
        default:
            return .release(selection: selection)
        }
    }

    public static func grab(_ types: [ClipboardDataType], selectionHeader: Bool) -> AgentMessage {
        var w = header(selectionHeader)
        for type in types { w.writeU32(type.rawValue) }
        return AgentMessage(type: .clipboardGrab, data: w.bytes)
    }

    public static func request(_ type: ClipboardDataType, selectionHeader: Bool) -> AgentMessage {
        var w = header(selectionHeader)
        w.writeU32(type.rawValue)
        return AgentMessage(type: .clipboardRequest, data: w.bytes)
    }

    public static func data(_ type: ClipboardDataType, bytes: [UInt8], selectionHeader: Bool) -> AgentMessage {
        var w = header(selectionHeader)
        w.writeU32(type.rawValue)
        w.writeBytes(bytes.prefix(maxDataSize))
        return AgentMessage(type: .clipboard, data: w.bytes)
    }

    public static func release(selectionHeader: Bool) -> AgentMessage {
        AgentMessage(type: .clipboardRelease, data: header(selectionHeader).bytes)
    }

    private static func header(_ present: Bool) -> ByteWriter {
        var w = ByteWriter()
        if present { w.writeBytes([ClipboardSelection.clipboard.rawValue, 0, 0, 0]) }
        return w
    }

    // MARK: Text line endings

    /// macOS text → guest: LF → CRLF for guests that announce CRLF line endings (Windows).
    public static func textToGuest(_ text: String, guestUsesCRLF: Bool) -> [UInt8] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        return Array((guestUsesCRLF ? normalized.replacingOccurrences(of: "\n", with: "\r\n") : normalized).utf8)
    }

    /// Guest text → macOS: strips trailing NULs and CRLF → LF. Invalid UTF-8 is repaired.
    public static func textFromGuest(_ bytes: [UInt8]) -> String {
        var trimmed = bytes[...]
        while trimmed.last == 0 { trimmed = trimmed.dropLast() }
        return String(decoding: trimmed, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    }
}
