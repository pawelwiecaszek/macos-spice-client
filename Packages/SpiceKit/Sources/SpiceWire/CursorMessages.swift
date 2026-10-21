// Cursor channel (spice.proto `channel CursorChannel`).

/// `SpiceCursorType` (enums.h).
public enum CursorType: UInt8, Sendable {
    case alpha = 0, mono, color4, color8, color16, color24, color32
}

/// `SpiceCursorFlags` (enums.h).
public struct CursorFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    /// No cursor shape is included (and the cursor is hidden).
    public static let none = CursorFlags(rawValue: 1 << 0)
    public static let cacheMe = CursorFlags(rawValue: 1 << 1)
    public static let fromCache = CursorFlags(rawValue: 1 << 2)
}

/// `SpiceCursorHeader`.
public struct CursorHeader: Sendable, Hashable {
    public var unique: UInt64
    public var rawType: UInt8
    public var width: UInt16
    public var height: UInt16
    public var hotSpotX: UInt16
    public var hotSpotY: UInt16

    public var type: CursorType? { CursorType(rawValue: rawType) }

    public init(unique: UInt64, rawType: UInt8, width: UInt16, height: UInt16, hotSpotX: UInt16, hotSpotY: UInt16) {
        self.unique = unique
        self.rawType = rawType
        self.width = width
        self.height = height
        self.hotSpotX = hotSpotX
        self.hotSpotY = hotSpotY
    }
}

/// `SpiceCursor`: flags, optional header, then shape data to the end of the message.
public struct CursorShape: Sendable, Hashable {
    public var flags: CursorFlags
    public var header: CursorHeader?
    public var data: ArraySlice<UInt8>

    static func decode(_ r: inout ByteReader) throws(WireError) -> CursorShape {
        let flags = CursorFlags(rawValue: try r.readU16())
        var header: CursorHeader?
        if !flags.contains(.none) {
            header = CursorHeader(
                unique: try r.readU64(), rawType: try r.readU8(),
                width: try r.readU16(), height: try r.readU16(),
                hotSpotX: try r.readU16(), hotSpotY: try r.readU16()
            )
        }
        return CursorShape(flags: flags, header: header, data: r.readRemaining())
    }
}

/// `SPICE_MSG_CURSOR_INIT`.
public struct CursorInit: Sendable, Hashable {
    public var position: Point16
    public var trailLength: UInt16
    public var trailFrequency: UInt16
    public var visible: Bool
    public var cursor: CursorShape

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        position = try Point16.decode(&r)
        trailLength = try r.readU16()
        trailFrequency = try r.readU16()
        visible = try r.readU8() != 0
        cursor = try CursorShape.decode(&r)
    }
}

/// `SPICE_MSG_CURSOR_SET`.
public struct CursorSet: Sendable, Hashable {
    public var position: Point16
    public var visible: Bool
    public var cursor: CursorShape

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        position = try Point16.decode(&r)
        visible = try r.readU8() != 0
        cursor = try CursorShape.decode(&r)
    }
}

/// `SPICE_MSG_CURSOR_MOVE`.
public struct CursorMove: Sendable, Hashable {
    public var position: Point16
    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        position = try Point16.decode(&r)
    }
}
