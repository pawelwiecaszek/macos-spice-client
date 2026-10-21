// Playback and record channels (spice.proto `channel PlaybackChannel` / `RecordChannel`;
// constants from spice-protocol enums.h / protocol.h, BSD-licensed).

/// `SpiceAudioDataMode`.
public enum AudioDataMode: UInt16, Sendable {
    case invalid = 0
    case raw = 1
    case celt051 = 2  // deprecated, never negotiated by this client
    case opus = 3
}

/// `SpiceAudioFmt`: only signed 16-bit little-endian exists.
public let audioFormatS16: UInt16 = 1

// `PlaybackCapability` lives in Constants.swift.

/// `SPICE_RECORD_CAP_*`.
public enum RecordCapability: Int, Sendable {
    case celt051 = 0, volume, opus
}

/// `SPICE_MSG_PLAYBACK_*`.
public enum PlaybackServerMessage: UInt16, Sendable {
    case data = 101, mode, start, stop, volume, mute, latency
}

/// `SPICE_MSG_RECORD_*`.
public enum RecordServerMessage: UInt16, Sendable {
    case start = 101, stop, volume, mute
}

/// `SPICE_MSGC_RECORD_*`.
public enum RecordClientMessage: UInt16, Sendable {
    case data = 101, mode, startMark
}

/// Playback/record START (`channels`, `format`, `frequency`, playback adds `time`).
public struct AudioStart: Sendable, Hashable {
    public var channels: UInt32
    public var format: UInt16
    public var frequency: UInt32
    public var time: UInt32?

    public init(decoding bytes: [UInt8], hasTime: Bool) throws(WireError) {
        var r = ByteReader(bytes)
        channels = try r.readU32()
        format = try r.readU16()
        frequency = try r.readU32()
        time = hasTime ? try r.readU32() : nil
        guard (1...8).contains(channels), (8000...192_000).contains(frequency) else {
            throw .invalidValue("audio \(channels) ch @ \(frequency) Hz")
        }
    }
}

/// PLAYBACK_DATA (`time`, data) and PLAYBACK_MODE (`time`, `mode`, data).
public struct AudioPacket: Sendable, Hashable {
    public var time: UInt32
    public var mode: AudioDataMode?
    public var data: [UInt8]

    public init(decodingData bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        time = try r.readU32()
        mode = nil
        data = Array(bytes.dropFirst(4))
    }

    public init(decodingMode bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        time = try r.readU32()
        mode = AudioDataMode(rawValue: try r.readU16()) ?? .invalid
        data = Array(bytes.dropFirst(6))
    }
}

/// `AudioVolume`: per-channel volume, 0…65535.
public struct AudioVolume: Sendable, Hashable {
    public var levels: [UInt16]

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        let count = Int(try r.readU8())
        var levels: [UInt16] = []
        for _ in 0..<count { levels.append(try r.readU16()) }
        self.levels = levels
    }

    /// Average level as 0…1.
    public var normalized: Float {
        guard !levels.isEmpty else { return 1 }
        return Float(levels.reduce(0) { $0 + Int($1) }) / Float(levels.count) / 65535
    }
}

public enum RecordClientEncoder {
    public static func mode(_ mode: AudioDataMode, time: UInt32) -> SpiceMessage {
        var w = ByteWriter()
        w.writeU32(time)
        w.writeU16(mode.rawValue)
        return SpiceMessage(type: RecordClientMessage.mode.rawValue, payload: w.bytes)
    }

    public static func startMark(time: UInt32) -> SpiceMessage {
        var w = ByteWriter()
        w.writeU32(time)
        return SpiceMessage(type: RecordClientMessage.startMark.rawValue, payload: w.bytes)
    }

    public static func data(_ bytes: [UInt8], time: UInt32) -> SpiceMessage {
        var w = ByteWriter(capacity: 4 + bytes.count)
        w.writeU32(time)
        w.writeBytes(bytes)
        return SpiceMessage(type: RecordClientMessage.data.rawValue, payload: w.bytes)
    }
}
