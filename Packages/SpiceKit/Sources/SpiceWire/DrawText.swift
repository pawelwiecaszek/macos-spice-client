/// Packed glyph coverage formats (`string_flags`, spice-common@58d375e).
public enum GlyphFormat: UInt8, Sendable, Hashable {
    case a1 = 1
    case a4 = 2
    case a8 = 4

    public var bitsPerPixel: Int {
        switch self { case .a1: 1; case .a4: 4; case .a8: 8 }
    }
}

/// One tightly packed raster glyph. Coverage rows have no four-byte alignment.
public struct RasterGlyph: Sendable, Hashable {
    public let renderPosition: Point
    public let origin: Point
    public let width: Int
    public let height: Int
    public let data: [UInt8]

    public init(renderPosition: Point, origin: Point, width: Int, height: Int, data: [UInt8]) {
        self.renderPosition = renderPosition; self.origin = origin
        self.width = width; self.height = height; self.data = data
    }

    /// Adding signed server coordinates must not wrap at either rectangle edge.
    public func bounds() throws(WireError) -> Rect {
        guard (0...RasterString.maxDimension).contains(width),
              (0...RasterString.maxDimension).contains(height) else { throw .limitExceeded("text glyph dimensions") }
        let left = Int64(renderPosition.x) + Int64(origin.x)
        let top = Int64(renderPosition.y) + Int64(origin.y)
        let right = left + Int64(width), bottom = top + Int64(height)
        guard let x0 = Int32(exactly: left), let y0 = Int32(exactly: top),
              let x1 = Int32(exactly: right), let y1 = Int32(exactly: bottom) else {
            throw .invalidValue("text glyph bounds")
        }
        return Rect(left: x0, top: y0, right: x1, bottom: y1)
    }
}

/// `SpiceString`: glyphs are inline variable-sized records on the wire. The
/// schema's `@ptr_array` describes the generated C representation, not offsets.
public struct RasterString: Sendable, Hashable {
    public static let maxGlyphs = 4096
    public static let maxDimension = 16_384
    public static let maxPixels = 8 * 1024 * 1024
    public static let maxDataBytes = 8 * 1024 * 1024

    public let format: GlyphFormat
    public let topDown: Bool
    public let glyphs: [RasterGlyph]
    public var flags: UInt8 { format.rawValue | (topDown ? 8 : 0) }

    public init(format: GlyphFormat, topDown: Bool = false, glyphs: [RasterGlyph]) {
        self.format = format; self.topDown = topDown; self.glyphs = glyphs
    }

    /// Also validates models constructed directly by callers before raster work.
    public func validate() throws(WireError) {
        guard glyphs.count <= Self.maxGlyphs else { throw .limitExceeded("text glyph count") }
        var pixels = 0, bytes = 0
        for glyph in glyphs {
            _ = try glyph.bounds()
            let count = glyph.width * glyph.height
            let size = ((glyph.width * format.bitsPerPixel + 7) / 8) * glyph.height
            guard count <= Self.maxPixels - pixels else { throw .limitExceeded("text glyph pixels") }
            guard size <= Self.maxDataBytes - bytes else { throw .limitExceeded("text glyph data") }
            guard glyph.data.count == size else { throw .invalidValue("text glyph data length") }
            pixels += count; bytes += size
        }
    }

    static func decode(_ reader: inout ByteReader) throws(WireError) -> Self {
        let count = Int(try reader.readU16()), flags = try reader.readU8()
        guard count <= maxGlyphs else { throw .limitExceeded("text glyph count") }
        guard flags & ~UInt8(15) == 0, let format = GlyphFormat(rawValue: flags & 7) else {
            throw .invalidValue("text string flags")
        }
        var glyphs: [RasterGlyph] = [], pixels = 0, bytes = 0
        glyphs.reserveCapacity(count)
        for _ in 0..<count {
            let position = try Point.decode(&reader), origin = try Point.decode(&reader)
            let width = Int(try reader.readU16()), height = Int(try reader.readU16())
            guard width <= maxDimension, height <= maxDimension else { throw .limitExceeded("text glyph dimensions") }
            let area = width * height, size = ((width * format.bitsPerPixel + 7) / 8) * height
            guard area <= maxPixels - pixels else { throw .limitExceeded("text glyph pixels") }
            guard size <= maxDataBytes - bytes else { throw .limitExceeded("text glyph data") }
            // Check geometry before copying any server-controlled glyph data.
            let geometry = RasterGlyph(renderPosition: position, origin: origin, width: width, height: height, data: [])
            _ = try geometry.bounds()
            let data = Array(try reader.readBytes(size))
            glyphs.append(RasterGlyph(renderPosition: position, origin: origin, width: width, height: height, data: data))
            pixels += area; bytes += size
        }
        return Self(format: format, topDown: flags & 8 != 0, glyphs: glyphs)
    }
}

/// Packed `DRAW_TEXT`, spice-common@58d375e spice.proto:658–693,870–880.
public struct DrawText: Sendable, Hashable {
    public let base: DisplayBase
    public let string: RasterString
    public let backgroundArea: Rect
    public let foregroundBrush: Brush
    public let backgroundBrush: Brush
    public let foreMode: Ropd
    public let backMode: Ropd

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var reader = ByteReader(bytes)
        base = try DisplayBase.decode(&reader)
        let pointer = try reader.readU32()
        backgroundArea = try Rect.decode(&reader)
        foregroundBrush = try Brush.decode(&reader)
        backgroundBrush = try Brush.decode(&reader)
        foreMode = Ropd(rawValue: try reader.readU16())
        backMode = Ropd(rawValue: try reader.readU16())
        guard pointer != 0, pointer >= reader.offset else { throw .invalidValue("text string offset") }
        var glyphReader = try reader.reader(atPointer: pointer)
        string = try RasterString.decode(&glyphReader)
    }
}
