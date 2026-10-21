// Wire constants transcribed from spice-protocol 0.14.3 (BSD-licensed):
// spice/protocol.h and spice/enums.h. Raw values must match the headers exactly.

/// `SPICE_MAGIC` — "REDQ" read as a little-endian uint32.
public let spiceMagic: UInt32 = 0x5144_4552
/// `SPICE_VERSION_MAJOR` / `SPICE_VERSION_MINOR` (protocol.h).
public let spiceVersionMajor: UInt32 = 2
public let spiceVersionMinor: UInt32 = 2
/// `SPICE_TICKET_PUBKEY_BYTES` = 1024 / 8 + 34 (protocol.h).
public let spiceTicketPublicKeyBytes = 162
/// RSA-1024 ciphertext size (`SpiceLinkEncryptedTicket`).
public let spiceEncryptedTicketBytes = 128
/// `SPICE_MAX_PASSWORD_LENGTH` (protocol.h).
public let spiceMaxPasswordLength = 60
/// `SPICE_INPUT_MOTION_ACK_BUNCH` (protocol.h).
public let spiceInputMotionAckBunch = 4

/// `SPICE_CHANNEL_*` (enums.h).
public enum ChannelType: UInt8, Sendable, CaseIterable, CustomStringConvertible {
    case main = 1
    case display
    case inputs
    case cursor
    case playback
    case record
    case tunnel
    case smartcard
    case usbredir
    case port
    case webdav

    public var description: String {
        switch self {
        case .main: "main"
        case .display: "display"
        case .inputs: "inputs"
        case .cursor: "cursor"
        case .playback: "playback"
        case .record: "record"
        case .tunnel: "tunnel"
        case .smartcard: "smartcard"
        case .usbredir: "usbredir"
        case .port: "port"
        case .webdav: "webdav"
        }
    }
}

/// `SpiceLinkErr` (enums.h).
public enum LinkError: UInt32, Error, Sendable {
    case ok = 0
    case error
    case invalidMagic
    case invalidData
    case versionMismatch
    case needSecured
    case needUnsecured
    case permissionDenied
    case badConnectionID
    case channelNotAvailable
}

/// `SPICE_COMMON_CAP_*` (protocol.h) — bit indices.
public enum CommonCapability: Int, Sendable {
    case protocolAuthSelection = 0
    case authSpice = 1
    case authSASL = 2
    case miniHeader = 3
}

/// `SPICE_MAIN_CAP_*` (protocol.h).
public enum MainCapability: Int, Sendable {
    case semiSeamlessMigrate = 0
    case nameAndUUID = 1
    case agentConnectedTokens = 2
    case seamlessMigrate = 3
}

/// `SPICE_DISPLAY_CAP_*` (protocol.h).
public enum DisplayCapability: Int, Sendable {
    case sizedStream = 0
    case monitorsConfig
    case composite
    case a8Surface
    case streamReport
    case lz4Compression
    case prefCompression
    case glScanout
    case multiCodec
    case codecMJPEG
    case codecVP8
    case codecH264
    case prefVideoCodecType
    case codecVP9
    case codecH265
}

/// `SPICE_INPUTS_CAP_*` (protocol.h).
public enum InputsCapability: Int, Sendable {
    case keyScancode = 0
}

/// `SPICE_PLAYBACK_CAP_*` / `SPICE_RECORD_CAP_*` (protocol.h).
public enum PlaybackCapability: Int, Sendable {
    case celt051 = 0, volume, latency, opus
}

/// `SPICE_SPICEVMC_CAP_*` (protocol.h).
public enum SpiceVMCCapability: Int, Sendable {
    case dataCompressLZ4 = 0
}

/// `SpiceMouseMode` (enums.h) — flags.
public struct MouseModes: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let server = MouseModes(rawValue: 1 << 0)
    public static let client = MouseModes(rawValue: 1 << 1)
}

/// `SpiceMouseButton` (enums.h).
public enum MouseButton: UInt8, Sendable {
    case invalid = 0, left, middle, right, up, down, side, extra
}

/// `SpiceMouseButtonMask` (enums.h).
public struct MouseButtonMask: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let left = MouseButtonMask(rawValue: 1 << 0)
    public static let middle = MouseButtonMask(rawValue: 1 << 1)
    public static let right = MouseButtonMask(rawValue: 1 << 2)
    public static let up = MouseButtonMask(rawValue: 1 << 3)
    public static let down = MouseButtonMask(rawValue: 1 << 4)
    public static let side = MouseButtonMask(rawValue: 1 << 5)
    public static let extra = MouseButtonMask(rawValue: 1 << 6)

    public init(button: MouseButton) {
        switch button {
        case .invalid: self = []
        case .left: self = .left
        case .middle: self = .middle
        case .right: self = .right
        case .up: self = .up
        case .down: self = .down
        case .side: self = .side
        case .extra: self = .extra
        }
    }
}

/// `SpiceKeyboardModifierFlags` (enums.h).
public struct KeyboardModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let scrollLock = KeyboardModifiers(rawValue: 1 << 0)
    public static let numLock = KeyboardModifiers(rawValue: 1 << 1)
    public static let capsLock = KeyboardModifiers(rawValue: 1 << 2)
}

/// `SpiceNotifySeverity` (enums.h).
public enum NotifySeverity: UInt32, Sendable {
    case info = 0, warn, error
}

/// `SpiceImageCompression` (enums.h).
public enum ImageCompression: UInt8, Sendable {
    case invalid = 0, off, autoGLZ, autoLZ, quic, glz, lz, lz4
}

/// `SpiceVideoCodecType` (enums.h).
public enum VideoCodecType: UInt8, Sendable {
    case mjpeg = 1, vp8, h264, vp9, h265
}

/// `SpiceDataCompressionType` (enums.h).
public enum DataCompressionType: UInt8, Sendable {
    case none = 0, lz4
}
