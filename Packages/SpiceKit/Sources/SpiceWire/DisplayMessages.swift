// Display channel message bodies (spice.proto `channel DisplayChannel`).
// Pointer fields (`Image *`, `Palette *`) are uint32 offsets from the message start.

/// `SpiceRopd` (enums.h) — raster operation descriptor.
public struct Ropd: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let inversSource = Ropd(rawValue: 1 << 0)
    public static let inversBrush = Ropd(rawValue: 1 << 1)
    public static let inversDest = Ropd(rawValue: 1 << 2)
    public static let opPut = Ropd(rawValue: 1 << 3)
    public static let opOr = Ropd(rawValue: 1 << 4)
    public static let opAnd = Ropd(rawValue: 1 << 5)
    public static let opXor = Ropd(rawValue: 1 << 6)
    public static let opBlackness = Ropd(rawValue: 1 << 7)
    public static let opWhiteness = Ropd(rawValue: 1 << 8)
    public static let opInvers = Ropd(rawValue: 1 << 9)
    public static let inversResult = Ropd(rawValue: 1 << 10)
}

/// `SpiceImageScaleMode` (enums.h).
public enum ScaleMode: UInt8, Sendable {
    case interpolate = 0
    case nearest = 1
}

/// `SpiceBrush`.
public enum Brush: Sendable, Hashable {
    case none
    /// xRGB color.
    case solid(UInt32)
    case pattern(Image?, position: Point)

    static func decode(_ r: inout ByteReader) throws(WireError) -> Brush {
        let type = try r.readU8()
        switch type {
        case 0: return Brush.none
        case 1: return .solid(try r.readU32())
        case 2:
            let pointer = try r.readU32()
            let position = try Point.decode(&r)
            return .pattern(try Image.decode(at: pointer, in: r), position: position)
        default: throw .invalidValue("brush type \(type)")
        }
    }
}

/// `SpiceQMask`: optional 1-bpp mask.
public struct QMask: Sendable, Hashable {
    public var inverted: Bool
    public var position: Point
    public var bitmap: Image?

    static func decode(_ r: inout ByteReader) throws(WireError) -> QMask {
        let flags = try r.readU8()
        let position = try Point.decode(&r)
        let pointer = try r.readU32()
        return QMask(inverted: flags & 1 != 0, position: position, bitmap: try Image.decode(at: pointer, in: r))
    }
}

/// `SpiceMsgDisplayBase`.
public struct DisplayBase: Sendable, Hashable {
    public var surfaceID: UInt32
    public var box: Rect
    public var clip: Clip

    public init(surfaceID: UInt32, box: Rect, clip: Clip) {
        self.surfaceID = surfaceID
        self.box = box
        self.clip = clip
    }

    static func decode(_ r: inout ByteReader) throws(WireError) -> DisplayBase {
        DisplayBase(surfaceID: try r.readU32(), box: try Rect.decode(&r), clip: try Clip.decode(&r))
    }
}

/// `SpiceSurfaceFmt` (enums.h).
public enum SurfaceFormat: UInt32, Sendable {
    case invalid = 0
    case a1 = 1
    case a8 = 8
    case x555 = 16
    case xRGB32 = 32
    case r565 = 80
    case argb32 = 96
}

/// `SPICE_MSG_DISPLAY_SURFACE_CREATE`.
public struct SurfaceCreate: Sendable, Hashable {
    public var surfaceID: UInt32
    public var width: UInt32
    public var height: UInt32
    public var rawFormat: UInt32
    /// `SPICE_SURFACE_FLAGS_PRIMARY` = 1.
    public var flags: UInt32

    public var isPrimary: Bool { flags & 1 != 0 }
    public var format: SurfaceFormat? { SurfaceFormat(rawValue: rawFormat) }

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        surfaceID = try r.readU32()
        width = try r.readU32()
        height = try r.readU32()
        rawFormat = try r.readU32()
        flags = try r.readU32()
    }
}

/// `SPICE_MSG_DISPLAY_SURFACE_DESTROY`.
public struct SurfaceDestroy: Sendable, Hashable {
    public var surfaceID: UInt32
    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        surfaceID = try r.readU32()
    }
}

/// `SPICE_MSG_DISPLAY_DRAW_FILL`.
public struct DrawFill: Sendable, Hashable {
    public var base: DisplayBase
    public var brush: Brush
    public var rop: Ropd
    public var mask: QMask

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        base = try DisplayBase.decode(&r)
        brush = try Brush.decode(&r)
        rop = Ropd(rawValue: try r.readU16())
        mask = try QMask.decode(&r)
    }
}

/// `SPICE_MSG_DISPLAY_DRAW_COPY` and `SPICE_MSG_DISPLAY_DRAW_BLEND` (same layout).
public struct DrawCopy: Sendable, Hashable {
    public var base: DisplayBase
    public var source: Image?
    public var sourceArea: Rect
    public var rop: Ropd
    public var scaleMode: ScaleMode
    public var mask: QMask

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        base = try DisplayBase.decode(&r)
        let pointer = try r.readU32()
        source = try Image.decode(at: pointer, in: r)
        sourceArea = try Rect.decode(&r)
        rop = Ropd(rawValue: try r.readU16())
        scaleMode = ScaleMode(rawValue: try r.readU8()) ?? .nearest
        mask = try QMask.decode(&r)
    }
}

/// `SPICE_MSG_DISPLAY_DRAW_OPAQUE`.
public struct DrawOpaque: Sendable, Hashable {
    public var base: DisplayBase
    public var source: Image?
    public var sourceArea: Rect
    public var brush: Brush
    public var rop: Ropd
    public var scaleMode: ScaleMode
    public var mask: QMask

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        base = try DisplayBase.decode(&r)
        let pointer = try r.readU32()
        source = try Image.decode(at: pointer, in: r)
        sourceArea = try Rect.decode(&r)
        brush = try Brush.decode(&r)
        rop = Ropd(rawValue: try r.readU16())
        scaleMode = ScaleMode(rawValue: try r.readU8()) ?? .nearest
        mask = try QMask.decode(&r)
    }
}

/// `SPICE_MSG_DISPLAY_DRAW_BLACKNESS` / `WHITENESS` / `INVERS`.
public struct DrawMaskOnly: Sendable, Hashable {
    public var base: DisplayBase
    public var mask: QMask

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        base = try DisplayBase.decode(&r)
        mask = try QMask.decode(&r)
    }
}

/// `SPICE_MSG_DISPLAY_DRAW_TRANSPARENT`.
public struct DrawTransparent: Sendable, Hashable {
    public var base: DisplayBase
    public var source: Image?
    public var sourceArea: Rect
    /// Pixels equal to this xRGB color are not drawn.
    public var sourceColor: UInt32
    public var trueColor: UInt32

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        base = try DisplayBase.decode(&r)
        let pointer = try r.readU32()
        source = try Image.decode(at: pointer, in: r)
        sourceArea = try Rect.decode(&r)
        sourceColor = try r.readU32()
        trueColor = try r.readU32()
    }
}

/// `SPICE_MSG_DISPLAY_DRAW_ALPHA_BLEND`.
public struct DrawAlphaBlend: Sendable, Hashable {
    public var base: DisplayBase
    /// `SPICE_ALPHA_FLAGS_DEST_HAS_ALPHA` = 1, `SRC_SURFACE_HAS_ALPHA` = 2.
    public var alphaFlags: UInt8
    public var alpha: UInt8
    public var source: Image?
    public var sourceArea: Rect

    public var sourceHasAlpha: Bool { alphaFlags & 2 != 0 }
    public var destinationHasAlpha: Bool { alphaFlags & 1 != 0 }

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        base = try DisplayBase.decode(&r)
        alphaFlags = try r.readU8()
        alpha = try r.readU8()
        let pointer = try r.readU32()
        source = try Image.decode(at: pointer, in: r)
        sourceArea = try Rect.decode(&r)
    }
}

/// `SPICE_MSG_DISPLAY_COPY_BITS`: copy within the same surface.
public struct CopyBits: Sendable, Hashable {
    public var base: DisplayBase
    public var sourcePosition: Point

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        base = try DisplayBase.decode(&r)
        sourcePosition = try Point.decode(&r)
    }
}

/// `SpiceResourceID`.
public struct ResourceID: Sendable, Hashable {
    public var type: UInt8
    public var id: UInt64
}

/// `SPICE_MSG_DISPLAY_INVAL_LIST`.
public struct InvalidateList: Sendable, Hashable {
    public var resources: [ResourceID]

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        let count = try r.readU16()
        resources = []
        resources.reserveCapacity(Int(count))
        for _ in 0..<count {
            resources.append(ResourceID(type: try r.readU8(), id: try r.readU64()))
        }
    }
}

/// `SPICE_MSG_DISPLAY_INVAL_PALETTE` (and cursor `INVAL_ONE`): a single id.
public struct InvalidateOne: Sendable, Hashable {
    public var id: UInt64
    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        id = try r.readU64()
    }
}

/// `SpiceHead` inside `SPICE_MSG_DISPLAY_MONITORS_CONFIG`.
public struct MonitorHead: Sendable, Hashable {
    public var monitorID: UInt32
    public var surfaceID: UInt32
    public var width: UInt32
    public var height: UInt32
    public var x: UInt32
    public var y: UInt32
    public var flags: UInt32
}

/// `SPICE_MSG_DISPLAY_MONITORS_CONFIG`.
public struct MonitorsConfig: Sendable, Hashable {
    public var maxAllowed: UInt16
    public var heads: [MonitorHead]

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        let count = try r.readU16()
        maxAllowed = try r.readU16()
        heads = []
        for _ in 0..<count {
            heads.append(MonitorHead(
                monitorID: try r.readU32(), surfaceID: try r.readU32(),
                width: try r.readU32(), height: try r.readU32(),
                x: try r.readU32(), y: try r.readU32(), flags: try r.readU32()
            ))
        }
    }
}

/// `SPICE_MSG_DISPLAY_STREAM_CREATE`.
public struct StreamCreate: Sendable, Hashable {
    public var surfaceID: UInt32
    public var streamID: UInt32
    /// `SPICE_STREAM_FLAGS_TOP_DOWN` = 1.
    public var flags: UInt8
    public var rawCodec: UInt8
    public var stamp: UInt64
    public var streamWidth: UInt32
    public var streamHeight: UInt32
    public var sourceWidth: UInt32
    public var sourceHeight: UInt32
    public var destination: Rect
    public var clip: Clip

    public var codec: VideoCodecType? { VideoCodecType(rawValue: rawCodec) }
    public var isTopDown: Bool { flags & 1 != 0 }

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        surfaceID = try r.readU32()
        streamID = try r.readU32()
        flags = try r.readU8()
        rawCodec = try r.readU8()
        stamp = try r.readU64()
        streamWidth = try r.readU32()
        streamHeight = try r.readU32()
        sourceWidth = try r.readU32()
        sourceHeight = try r.readU32()
        destination = try Rect.decode(&r)
        clip = try Clip.decode(&r)
    }
}

/// `SPICE_MSG_DISPLAY_STREAM_DATA` / `STREAM_DATA_SIZED`.
public struct StreamData: Sendable, Hashable {
    /// Extra fields of `STREAM_DATA_SIZED`: the frame size and destination changed.
    public struct Resize: Sendable, Hashable {
        public var width: UInt32
        public var height: UInt32
        public var destination: Rect
    }

    public var streamID: UInt32
    public var multimediaTime: UInt32
    public var resize: Resize?
    public var data: ArraySlice<UInt8>

    public init(decoding bytes: [UInt8], sized: Bool) throws(WireError) {
        var r = ByteReader(bytes)
        streamID = try r.readU32()
        multimediaTime = try r.readU32()
        if sized {
            resize = Resize(width: try r.readU32(), height: try r.readU32(), destination: try Rect.decode(&r))
        }
        let size = try r.readU32()
        data = try r.readBytes(Int(size))
    }
}

/// `SPICE_MSG_DISPLAY_STREAM_CLIP`.
public struct StreamClip: Sendable, Hashable {
    public var streamID: UInt32
    public var clip: Clip

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        streamID = try r.readU32()
        clip = try Clip.decode(&r)
    }
}

/// `SPICE_MSG_DISPLAY_STREAM_DESTROY`.
public struct StreamDestroy: Sendable, Hashable {
    public var streamID: UInt32
    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        streamID = try r.readU32()
    }
}

/// Client → server display messages.
/// `SPICE_MSG_DISPLAY_STREAM_ACTIVATE_REPORT`: the server wants playback statistics.
public struct StreamActivateReport: Sendable, Hashable {
    public var streamID: UInt32
    public var uniqueID: UInt32
    public var maxWindowSize: UInt32
    public var timeoutMS: UInt32

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var r = ByteReader(bytes)
        streamID = try r.readU32()
        uniqueID = try r.readU32()
        maxWindowSize = try r.readU32()
        timeoutMS = try r.readU32()
    }
}

/// `SPICE_MSGC_DISPLAY_STREAM_REPORT` fields.
public struct StreamReport: Sendable, Hashable {
    public var streamID: UInt32
    public var uniqueID: UInt32
    public var startFrameMMTime: UInt32
    public var endFrameMMTime: UInt32
    public var frames: UInt32
    public var drops: UInt32
    /// Frame time minus playback time of the last frame (negative = late).
    public var lastFrameDelay: Int32
    /// `UInt32.max` when there is no audio.
    public var audioDelay: UInt32

    public init(streamID: UInt32, uniqueID: UInt32, startFrameMMTime: UInt32, endFrameMMTime: UInt32,
                frames: UInt32, drops: UInt32, lastFrameDelay: Int32, audioDelay: UInt32 = .max) {
        self.streamID = streamID
        self.uniqueID = uniqueID
        self.startFrameMMTime = startFrameMMTime
        self.endFrameMMTime = endFrameMMTime
        self.frames = frames
        self.drops = drops
        self.lastFrameDelay = lastFrameDelay
        self.audioDelay = audioDelay
    }
}

public enum DisplayClientEncoder {
    public static func streamReport(_ report: StreamReport) -> SpiceMessage {
        var w = ByteWriter()
        w.writeU32(report.streamID)
        w.writeU32(report.uniqueID)
        w.writeU32(report.startFrameMMTime)
        w.writeU32(report.endFrameMMTime)
        w.writeU32(report.frames)
        w.writeU32(report.drops)
        w.writeI32(report.lastFrameDelay)
        w.writeU32(report.audioDelay)
        return SpiceMessage(type: DisplayClientMessage.streamReport.rawValue, payload: w.bytes)
    }

    /// `SPICE_MSGC_DISPLAY_INIT`.
    public static func initialize(pixmapCacheID: UInt8, pixmapCacheSize: Int64,
                                  glzDictionaryID: UInt8, glzWindowSize: Int32) -> SpiceMessage {
        var w = ByteWriter()
        w.writeU8(pixmapCacheID)
        w.writeI64(pixmapCacheSize)
        w.writeU8(glzDictionaryID)
        w.writeI32(glzWindowSize)
        return SpiceMessage(type: DisplayClientMessage.initialize.rawValue, payload: w.bytes)
    }

    /// `SPICE_MSGC_DISPLAY_PREFERRED_COMPRESSION`.
    public static func preferredCompression(_ compression: ImageCompression) -> SpiceMessage {
        SpiceMessage(type: DisplayClientMessage.preferredCompression.rawValue, payload: [compression.rawValue])
    }

    /// `SPICE_MSGC_DISPLAY_PREFERRED_VIDEO_CODEC_TYPE`.
    public static func preferredVideoCodecs(_ codecs: [VideoCodecType]) -> SpiceMessage {
        var w = ByteWriter()
        w.writeU8(UInt8(codecs.count))
        for codec in codecs { w.writeU8(codec.rawValue) }
        return SpiceMessage(type: DisplayClientMessage.preferredVideoCodecType.rawValue, payload: w.bytes)
    }

    /// `SPICE_MSGC_DISPLAY_STREAM_REPORT` with `num_frames = 0, num_drops = 0xffffffff`,
    /// which tells the server the client cannot decode this stream.
    public static func streamUnsupported(streamID: UInt32, uniqueID: UInt32) -> SpiceMessage {
        var w = ByteWriter()
        w.writeU32(streamID)
        w.writeU32(uniqueID)
        w.writeU32(0)  // start_frame_mm_time
        w.writeU32(0)  // end_frame_mm_time
        w.writeU32(0)  // num_frames
        w.writeU32(0xFFFF_FFFF)  // num_drops
        w.writeI32(0)  // last_frame_delay
        w.writeU32(0xFFFF_FFFF)  // audio_delay
        return SpiceMessage(type: DisplayClientMessage.streamReport.rawValue, payload: w.bytes)
    }
}
