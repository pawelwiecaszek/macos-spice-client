import SpiceWire

// File transfer to the guest agent (spice-protocol vd_agent.h, BSD-licensed):
// FILE_XFER_START (id + key-file text), FILE_XFER_STATUS (id, result[, detail]),
// FILE_XFER_DATA (id, u64 size, bytes).

/// `VD_AGENT_FILE_XFER_STATUS_*`.
public enum FileTransferResult: UInt32, Sendable {
    case canSendData = 0
    case cancelled
    case error
    case success
    case notEnoughSpace
    case sessionLocked
    case agentNotConnected
    case disabled
}

public enum FileTransferCodec {
    /// Bytes per FILE_XFER_DATA message.
    public static let chunkSize = 32 * 1024

    /// START: `[vdagent-file-xfer]` key file with the file name and size, NUL-terminated.
    public static func start(id: UInt32, name: String, size: UInt64) -> AgentMessage {
        var w = ByteWriter()
        w.writeU32(id)
        w.writeBytes(Array("[vdagent-file-xfer]\nname=\(escapedName(name))\nsize=\(size)\n".utf8))
        w.writeU8(0)
        return AgentMessage(type: .fileXferStart, data: w.bytes)
    }

    public static func data(id: UInt32, bytes: ArraySlice<UInt8>) -> AgentMessage {
        var w = ByteWriter(capacity: 12 + bytes.count)
        w.writeU32(id)
        w.writeU64(UInt64(bytes.count))
        w.writeBytes(bytes)
        return AgentMessage(type: .fileXferData, data: w.bytes)
    }

    public static func status(id: UInt32, result: FileTransferResult) -> AgentMessage {
        var w = ByteWriter()
        w.writeU32(id)
        w.writeU32(result.rawValue)
        return AgentMessage(type: .fileXferStatus, data: w.bytes)
    }

    /// (id, result) of a FILE_XFER_STATUS from the guest.
    public static func decodeStatus(_ message: AgentMessage) -> (id: UInt32, result: FileTransferResult)? {
        guard message.knownType == .fileXferStatus else { return nil }
        var r = ByteReader(message.data)
        guard let id = try? r.readU32(), let raw = try? r.readU32() else { return nil }
        return (id, FileTransferResult(rawValue: raw) ?? .error)
    }

    /// Key-file value escaping; path separators and control characters are replaced so the
    /// guest can only ever create a plain file name in its download folder.
    static func escapedName(_ name: String) -> String {
        var cleaned = String(name.unicodeScalars.map { scalar -> Character in
            if scalar.properties.generalCategory == .control || scalar == "/" || scalar == "\\" { return "_" }
            return Character(scalar)
        })
        if cleaned.hasPrefix(".") { cleaned = "_" + cleaned.dropFirst() }
        if cleaned.isEmpty { cleaned = "file" }
        if cleaned.hasPrefix(" ") { cleaned = "\\s" + cleaned.dropFirst() }
        return cleaned
    }
}
