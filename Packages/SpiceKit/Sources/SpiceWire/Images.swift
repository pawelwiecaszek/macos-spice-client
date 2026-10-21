/// `SpiceImageType` (enums.h).
public enum ImageType: UInt8, Sendable {
    case bitmap = 0
    case quic = 1
    case reserved = 2
    case lzPLT = 100
    case lzRGB
    case glzRGB
    case fromCache
    case surface
    case jpeg
    case fromCacheLossless
    case zlibGLZRGB
    case jpegAlpha
    case lz4
}

/// `SpiceImageFlags` (enums.h).
public struct ImageFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let cacheMe = ImageFlags(rawValue: 1 << 0)
    public static let highBitsSet = ImageFlags(rawValue: 1 << 1)
    public static let cacheReplaceMe = ImageFlags(rawValue: 1 << 2)
}

/// `SpiceBitmapFmt` (enums.h).
public enum BitmapFormat: UInt8, Sendable {
    case invalid = 0
    case oneBitLE
    case oneBitBE
    case fourBitLE
    case fourBitBE
    case eightBit
    case sixteenBit  // x555
    case twentyFourBit  // BGR
    case thirtyTwoBit  // xRGB little-endian (BGRx in memory)
    case rgba  // ARGB little-endian (BGRA in memory)
    case eightBitAlpha

    public var isPaletted: Bool {
        switch self {
        case .oneBitLE, .oneBitBE, .fourBitLE, .fourBitBE, .eightBit: true
        default: false
        }
    }
}

/// `SpiceBitmapFlags` (enums.h).
public struct BitmapFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let paletteCacheMe = BitmapFlags(rawValue: 1 << 0)
    public static let paletteFromCache = BitmapFlags(rawValue: 1 << 1)
    public static let topDown = BitmapFlags(rawValue: 1 << 2)
}

/// `SpicePalette`: entries are xRGB (0x00RRGGBB).
public struct Palette: Sendable, Hashable {
    public var unique: UInt64
    public var entries: [UInt32]

    public init(unique: UInt64, entries: [UInt32]) {
        self.unique = unique
        self.entries = entries
    }

    static func decode(_ reader: inout ByteReader) throws(WireError) -> Palette {
        let unique = try reader.readU64()
        let count = try reader.readU16()
        guard Int(count) * 4 <= reader.remaining else {
            throw .truncated(needed: Int(count) * 4, available: reader.remaining)
        }
        var entries: [UInt32] = []
        entries.reserveCapacity(Int(count))
        for _ in 0..<count { entries.append(try reader.readU32()) }
        return Palette(unique: unique, entries: entries)
    }
}

/// Where a paletted image gets its palette from.
public enum PaletteReference: Sendable, Hashable {
    case none
    case inline(Palette)
    case cached(id: UInt64)
}

/// `SpiceBitmap`: an uncompressed image.
public struct BitmapData: Sendable, Hashable {
    public var format: BitmapFormat
    public var flags: BitmapFlags
    public var width: UInt32
    public var height: UInt32
    public var stride: UInt32
    public var palette: PaletteReference
    /// `stride * height` bytes.
    public var data: ArraySlice<UInt8>

    public init(format: BitmapFormat, flags: BitmapFlags, width: UInt32, height: UInt32, stride: UInt32,
                palette: PaletteReference, data: ArraySlice<UInt8>) {
        self.format = format
        self.flags = flags
        self.width = width
        self.height = height
        self.stride = stride
        self.palette = palette
        self.data = data
    }
}

/// `SpiceLZPLTData`.
public struct LZPaletteData: Sendable, Hashable {
    public var flags: BitmapFlags
    public var palette: PaletteReference
    public var data: ArraySlice<UInt8>
}

/// `SpiceImageDescriptor`.
public struct ImageDescriptor: Sendable, Hashable {
    /// Cache key when `.cacheMe` is set or the type is `.fromCache*`.
    public var id: UInt64
    public var rawType: UInt8
    public var flags: ImageFlags
    public var width: UInt32
    public var height: UInt32

    public var type: ImageType? { ImageType(rawValue: rawType) }
}

/// Image payload by type.
public enum ImagePayload: Sendable, Hashable {
    case bitmap(BitmapData)
    case quic(ArraySlice<UInt8>)
    case lzRGB(ArraySlice<UInt8>)
    case glzRGB(ArraySlice<UInt8>)
    case jpeg(ArraySlice<UInt8>)
    case lz4(ArraySlice<UInt8>)
    case lzPLT(LZPaletteData)
    case zlibGLZRGB(glzDataSize: UInt32, data: ArraySlice<UInt8>)
    case jpegAlpha(topDown: Bool, jpegSize: UInt32, data: ArraySlice<UInt8>)
    case surface(id: UInt32)
    /// `FROM_CACHE` / `FROM_CACHE_LOSSLESS`: look up `descriptor.id`.
    case fromCache(lossless: Bool)
}

/// `SpiceImage`: descriptor + payload.
public struct Image: Sendable, Hashable {
    public var descriptor: ImageDescriptor
    public var payload: ImagePayload

    /// Largest width/height accepted for any image (matches the surface cap).
    public static let maxDimension: UInt32 = 16_384

    /// Decodes the image a pointer field refers to. Returns `nil` for a null pointer.
    public static func decode(at pointer: UInt32, in reader: ByteReader) throws(WireError) -> Image? {
        guard pointer != 0 else { return nil }
        var r = try reader.reader(atPointer: pointer)
        return try decode(&r)
    }

    static func decode(_ r: inout ByteReader) throws(WireError) -> Image {
        let descriptor = ImageDescriptor(
            id: try r.readU64(),
            rawType: try r.readU8(),
            flags: ImageFlags(rawValue: try r.readU8()),
            width: try r.readU32(),
            height: try r.readU32()
        )
        guard descriptor.width <= maxDimension, descriptor.height <= maxDimension else {
            throw .limitExceeded("image \(descriptor.width)x\(descriptor.height)")
        }
        guard let type = descriptor.type else {
            throw .invalidValue("image type \(descriptor.rawType)")
        }

        func binary(_ r: inout ByteReader) throws(WireError) -> ArraySlice<UInt8> {
            let size = try r.readU32()
            return try r.readBytes(Int(size))
        }

        let payload: ImagePayload
        switch type {
        case .bitmap:
            let format = try r.readU8()
            let flags = BitmapFlags(rawValue: try r.readU8())
            let width = try r.readU32()
            let height = try r.readU32()
            let stride = try r.readU32()
            let palette = try decodePaletteReference(flags: flags, reader: &r)
            guard let bitmapFormat = BitmapFormat(rawValue: format), bitmapFormat != .invalid else {
                throw .invalidValue("bitmap format \(format)")
            }
            guard width <= maxDimension, height <= maxDimension else {
                throw .limitExceeded("bitmap \(width)x\(height)")
            }
            let size = UInt64(stride) * UInt64(height)
            guard size <= UInt64(r.remaining) else {
                throw .truncated(needed: Int(clamping: size), available: r.remaining)
            }
            payload = .bitmap(BitmapData(
                format: bitmapFormat, flags: flags, width: width, height: height,
                stride: stride, palette: palette, data: try r.readBytes(Int(size))
            ))
        case .quic: payload = .quic(try binary(&r))
        case .lzRGB: payload = .lzRGB(try binary(&r))
        case .glzRGB: payload = .glzRGB(try binary(&r))
        case .jpeg: payload = .jpeg(try binary(&r))
        case .lz4: payload = .lz4(try binary(&r))
        case .lzPLT:
            let flags = BitmapFlags(rawValue: try r.readU8())
            let size = try r.readU32()
            let palette = try decodePaletteReference(flags: flags, reader: &r)
            payload = .lzPLT(LZPaletteData(flags: flags, palette: palette, data: try r.readBytes(Int(size))))
        case .zlibGLZRGB:
            let glzSize = try r.readU32()
            let size = try r.readU32()
            payload = .zlibGLZRGB(glzDataSize: glzSize, data: try r.readBytes(Int(size)))
        case .jpegAlpha:
            let flags = try r.readU8()
            let jpegSize = try r.readU32()
            let size = try r.readU32()
            guard jpegSize <= size else { throw .invalidValue("jpeg alpha size") }
            payload = .jpegAlpha(topDown: flags & 1 != 0, jpegSize: jpegSize, data: try r.readBytes(Int(size)))
        case .surface:
            payload = .surface(id: try r.readU32())
        case .fromCache:
            payload = .fromCache(lossless: false)
        case .fromCacheLossless:
            payload = .fromCache(lossless: true)
        case .reserved:
            throw .invalidValue("reserved image type")
        }
        return Image(descriptor: descriptor, payload: payload)
    }

    private static func decodePaletteReference(
        flags: BitmapFlags, reader r: inout ByteReader
    ) throws(WireError) -> PaletteReference {
        if flags.contains(.paletteFromCache) {
            return .cached(id: try r.readU64())
        }
        let pointer = try r.readU32()
        guard pointer != 0 else { return PaletteReference.none }
        var paletteReader = try r.reader(atPointer: pointer)
        return .inline(try Palette.decode(&paletteReader))
    }
}
