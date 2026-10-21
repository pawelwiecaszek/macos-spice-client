import SpiceWire

/// SPICE "LZ" image decoder (`SPICE_IMAGE_TYPE_LZ_RGB` and `SPICE_IMAGE_TYPE_LZ_PLT`).
///
/// Written from the format's observable behaviour (a FastLZ-style byte stream with an
/// image header) and verified against fixtures produced by the reference encoder; see
/// `Tests/Fixtures/lz`. No reference implementation code is included.
///
/// Stream layout (all header words big-endian):
///   magic "LZ  " (0x20205a4c) · version 0x00010001 · type · width · height · stride · top_down
/// followed by control bytes:
///   * `ctrl < 32`  → `ctrl + 1` literal units follow.
///   * `ctrl >= 32` → back-reference. Length code = `ctrl >> 5` (7 = extended with
///     255-continued bytes), distance = `(ctrl & 31) << 8 | next byte`, with a 16-bit far
///     distance escape when both parts are all-ones. Length and distance carry biases that
///     depend on the image type.
public enum LZDecoder {
    /// `LzImageType` values.
    public enum ImageKind: UInt32, Sendable {
        case plt1LE = 1, plt1BE, plt4LE, plt4BE, plt8, rgb16, rgb24, rgb32, rgba, xxxa, a8

        var isPaletted: Bool { rawValue <= ImageKind.plt8.rawValue }

        /// Pixels encoded per literal unit (palette formats pack several pixels per byte).
        var pixelsPerUnit: Int {
            switch self {
            case .plt1LE, .plt1BE: 8
            case .plt4LE, .plt4BE: 2
            default: 1
            }
        }

        /// Bias added to the encoded match length.
        var lengthBias: Int {
            switch self {
            case .rgb16: 2
            case .rgb24, .rgb32, .rgba: 1
            default: 3  // palette, alpha and A8 streams
            }
        }
    }

    public struct Header: Sendable, Equatable {
        public var kind: ImageKind
        public var width: Int
        public var height: Int
        public var stride: Int
        public var topDown: Bool
    }

    static let magic: UInt32 = 0x2020_5A4C
    static let version: UInt32 = 0x0001_0001
    static let maxNearDistance = 8191

    /// Decodes a complete LZ stream to BGRA.
    /// - Parameter palette: required for `LZ_PLT` streams.
    public static func decode(_ data: ArraySlice<UInt8>, palette: Palette? = nil) throws(CodecError) -> PixelBuffer {
        var input = Input(data)
        let header = try readHeader(&input)
        try CodecLimits.check(width: header.width, height: header.height)

        var image: PixelBuffer
        switch header.kind {
        case .rgb24, .rgb32, .rgba, .xxxa, .rgb16, .a8:
            image = try decodeRGB(header, &input)
        case .plt1LE, .plt1BE, .plt4LE, .plt4BE, .plt8:
            guard let palette else { throw .missingPalette }
            image = try decodePaletted(header, palette: palette, &input)
        }
        if !header.topDown { image.flipVertically() }
        return image
    }

    static func readHeader(_ input: inout Input) throws(CodecError) -> Header {
        guard try input.readBE32() == magic else { throw .badMagic }
        let version = try input.readBE32()
        guard version == Self.version else { throw .unsupportedVersion(version) }
        let rawType = try input.readBE32()
        guard let kind = ImageKind(rawValue: rawType) else { throw .unsupportedType("lz type \(rawType)") }
        let width = Int(try input.readBE32())
        let height = Int(try input.readBE32())
        let stride = Int(try input.readBE32())
        let topDown = try input.readBE32() != 0
        return Header(kind: kind, width: width, height: height, stride: stride, topDown: topDown)
    }

    // MARK: RGB family

    private static func decodeRGB(_ header: Header, _ input: inout Input) throws(CodecError) -> PixelBuffer {
        let count = header.width * header.height
        var pixels = [UInt32](repeating: 0xFF00_0000, count: count)
        var hasAlpha = false
        switch header.kind {
        case .rgb24, .rgb32:
            try decompress(&input, into: &pixels, count: count, lengthBias: 1) { (input: inout Input) throws(CodecError) -> UInt32 in
                let b = UInt32(try input.read()), g = UInt32(try input.read()), r = UInt32(try input.read())
                return opaque(r: r, g: g, b: b)
            }
        case .rgb16:
            try decompress(&input, into: &pixels, count: count, lengthBias: 2) { (input: inout Input) throws(CodecError) -> UInt32 in
                let high = UInt16(try input.read()), low = UInt16(try input.read())
                return pixelFrom555(high << 8 | low)
            }
        case .rgba:
            try decompress(&input, into: &pixels, count: count, lengthBias: 1) { (input: inout Input) throws(CodecError) -> UInt32 in
                let b = UInt32(try input.read()), g = UInt32(try input.read()), r = UInt32(try input.read())
                return r << 16 | g << 8 | b
            }
            try decompressAlpha(&input, into: &pixels, count: count)
            hasAlpha = true
        case .xxxa:
            for i in 0..<count { pixels[i] = 0 }
            try decompressAlpha(&input, into: &pixels, count: count)
            hasAlpha = true
        case .a8:
            try decompress(&input, into: &pixels, count: count, lengthBias: 3) { (input: inout Input) throws(CodecError) -> UInt32 in
                UInt32(try input.read()) << 24
            }
            hasAlpha = true
        default:
            throw .unsupportedType("lz rgb \(header.kind)")
        }
        return PixelBuffer(width: header.width, height: header.height, pixels: pixels, hasAlpha: hasAlpha)
    }

    /// Generic LZ decompression where one literal unit produces one output pixel.
    private static func decompress(
        _ input: inout Input, into output: inout [UInt32], count: Int, lengthBias: Int,
        literal: (inout Input) throws(CodecError) -> UInt32
    ) throws(CodecError) {
        var op = 0
        while op < count {
            let ctrl = Int(try input.read())
            if ctrl >= 32 {
                let (length, distance) = try readMatch(ctrl: ctrl, &input, lengthBias: lengthBias)
                let ref = op - distance
                guard ref >= 0, op + length <= count else { throw .corrupt("lz match out of range") }
                for k in 0..<length { output[op + k] = output[ref + k] }
                op += length
            } else {
                let literals = ctrl + 1
                guard op + literals <= count else { throw .corrupt("lz literal overflow") }
                for _ in 0..<literals {
                    output[op] = try literal(&input)
                    op += 1
                }
            }
        }
    }

    /// Second pass of `RGBA`/`XXXA`: an independent LZ stream carrying only alpha bytes.
    private static func decompressAlpha(_ input: inout Input, into output: inout [UInt32], count: Int) throws(CodecError) {
        var op = 0
        while op < count {
            let ctrl = Int(try input.read())
            if ctrl >= 32 {
                let (length, distance) = try readMatch(ctrl: ctrl, &input, lengthBias: 3)
                let ref = op - distance
                guard ref >= 0, op + length <= count else { throw .corrupt("lz alpha match out of range") }
                for k in 0..<length {
                    output[op + k] = (output[op + k] & 0x00FF_FFFF) | (output[ref + k] & 0xFF00_0000)
                }
                op += length
            } else {
                let literals = ctrl + 1
                guard op + literals <= count else { throw .corrupt("lz alpha literal overflow") }
                for _ in 0..<literals {
                    output[op] = (output[op] & 0x00FF_FFFF) | UInt32(try input.read()) << 24
                    op += 1
                }
            }
        }
    }

    /// Decodes length/distance of a back-reference (both returned with biases applied).
    @inline(__always)
    private static func readMatch(ctrl: Int, _ input: inout Input, lengthBias: Int) throws(CodecError) -> (Int, Int) {
        var length = (ctrl >> 5) - 1
        var distance = (ctrl & 31) << 8
        if length == 6 {
            var code: UInt8
            repeat {
                code = try input.read()
                length += Int(code)
            } while code == 255
        }
        let code = Int(try input.read())
        distance += code
        if code == 255, distance - code == 31 << 8 {
            distance = Int(try input.read()) << 8
            distance += Int(try input.read())
            distance += maxNearDistance
        }
        return (length + lengthBias, distance + 1)
    }

    // MARK: Paletted

    private static func decodePaletted(_ header: Header, palette: Palette, _ input: inout Input) throws(CodecError) -> PixelBuffer {
        let unitsPerRow = header.stride
        guard unitsPerRow * header.kind.pixelsPerUnit >= header.width else {
            throw .corrupt("lz stride too small")
        }
        let units = unitsPerRow * header.height
        guard units <= CodecLimits.maxPixels else { throw .tooLarge(width: header.width, height: header.height) }

        // Decode the packed bytes first; back-references operate on whole bytes.
        var packed = [UInt8](repeating: 0, count: units)
        var op = 0
        while op < units {
            let ctrl = Int(try input.read())
            if ctrl >= 32 {
                let (length, distance) = try readMatch(ctrl: ctrl, &input, lengthBias: 3)
                let ref = op - distance
                guard ref >= 0, op + length <= units else { throw .corrupt("lz plt match out of range") }
                for k in 0..<length { packed[op + k] = packed[ref + k] }
                op += length
            } else {
                let literals = ctrl + 1
                guard op + literals <= units else { throw .corrupt("lz plt literal overflow") }
                for _ in 0..<literals {
                    packed[op] = try input.read()
                    op += 1
                }
            }
        }

        let entries = palette.entries
        guard !entries.isEmpty else { throw .missingPalette }
        @inline(__always) func color(_ index: Int) -> UInt32 {
            0xFF00_0000 | entries[index % entries.count]
        }

        var output = PixelBuffer(width: header.width, height: header.height)
        for row in 0..<header.height {
            let src = row * unitsPerRow
            let dst = row * header.width
            for x in 0..<header.width {
                let pixel: UInt32
                switch header.kind {
                case .plt8:
                    let index = Int(packed[src + x])
                    pixel = index < entries.count ? 0xFF00_0000 | entries[index] : 0xFF00_0000
                case .plt4BE:
                    let byte = packed[src + x / 2]
                    pixel = color(Int(x & 1 == 0 ? byte >> 4 : byte & 0x0F))
                case .plt4LE:
                    let byte = packed[src + x / 2]
                    pixel = color(Int(x & 1 == 0 ? byte & 0x0F : byte >> 4))
                case .plt1BE:
                    let bit = (packed[src + x / 8] >> (7 - UInt8(x & 7))) & 1
                    pixel = color(Int(bit))
                case .plt1LE:
                    let bit = (packed[src + x / 8] >> UInt8(x & 7)) & 1
                    pixel = color(Int(bit))
                default:
                    pixel = 0xFF00_0000
                }
                output.pixels[dst + x] = pixel
            }
        }
        return output
    }

    // MARK: Input

    struct Input {
        let bytes: ArraySlice<UInt8>
        var position: Int

        init(_ bytes: ArraySlice<UInt8>) {
            self.bytes = bytes
            self.position = bytes.startIndex
        }

        @inline(__always)
        mutating func read() throws(CodecError) -> UInt8 {
            guard position < bytes.endIndex else { throw .truncated }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func readBE32() throws(CodecError) -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 { value = value << 8 | UInt32(try read()) }
            return value
        }
    }
}
