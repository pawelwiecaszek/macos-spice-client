import SpiceWire

/// Decodes uncompressed `SpiceBitmap` data (all `SPICE_BITMAP_FMT_*`) to BGRA.
public enum BitmapDecoder {
    /// - Parameters:
    ///   - bitmap: the wire bitmap.
    ///   - palette: resolved palette for paletted formats (`nil` otherwise).
    public static func decode(_ bitmap: BitmapData, palette: Palette?) throws(CodecError) -> PixelBuffer {
        let width = Int(bitmap.width)
        let height = Int(bitmap.height)
        try CodecLimits.check(width: width, height: height)
        let stride = Int(bitmap.stride)
        guard stride >= minimumStride(format: bitmap.format, width: width) else {
            throw .corrupt("bitmap stride \(stride) too small for width \(width)")
        }
        guard bitmap.data.count >= stride * height else { throw .truncated }
        if bitmap.format.isPaletted, palette == nil { throw .missingPalette }

        let entries = palette?.entries ?? []
        @inline(__always)
        func lookup(_ index: Int) -> UInt32 {
            index < entries.count ? (0xFF00_0000 | entries[index]) : 0xFF00_0000
        }

        var output = PixelBuffer(width: width, height: height, hasAlpha: bitmap.format == .rgba || bitmap.format == .eightBitAlpha)
        let topDown = bitmap.flags.contains(.topDown)
        let base = bitmap.data.startIndex

        output.pixels.withUnsafeMutableBufferPointer { out in
            for row in 0..<height {
                let srcRow = base + row * stride
                let dstRow = (topDown ? row : height - 1 - row) * width
                let data = bitmap.data
                switch bitmap.format {
                case .thirtyTwoBit:
                    for x in 0..<width {
                        let p = srcRow + x * 4
                        out[dstRow + x] = opaque(r: UInt32(data[p + 2]), g: UInt32(data[p + 1]), b: UInt32(data[p]))
                    }
                case .rgba:
                    for x in 0..<width {
                        let p = srcRow + x * 4
                        out[dstRow + x] = UInt32(data[p]) | UInt32(data[p + 1]) << 8
                            | UInt32(data[p + 2]) << 16 | UInt32(data[p + 3]) << 24
                    }
                case .twentyFourBit:
                    for x in 0..<width {
                        let p = srcRow + x * 3
                        out[dstRow + x] = opaque(r: UInt32(data[p + 2]), g: UInt32(data[p + 1]), b: UInt32(data[p]))
                    }
                case .sixteenBit:
                    for x in 0..<width {
                        let p = srcRow + x * 2
                        out[dstRow + x] = pixelFrom555(UInt16(data[p]) | UInt16(data[p + 1]) << 8)
                    }
                case .eightBit:
                    for x in 0..<width { out[dstRow + x] = lookup(Int(data[srcRow + x])) }
                case .fourBitBE:
                    for x in 0..<width {
                        let byte = data[srcRow + x / 2]
                        out[dstRow + x] = lookup(Int(x & 1 == 0 ? byte >> 4 : byte & 0x0F))
                    }
                case .fourBitLE:
                    for x in 0..<width {
                        let byte = data[srcRow + x / 2]
                        out[dstRow + x] = lookup(Int(x & 1 == 0 ? byte & 0x0F : byte >> 4))
                    }
                case .oneBitBE:
                    for x in 0..<width {
                        let bit = (data[srcRow + x / 8] >> (7 - UInt8(x & 7))) & 1
                        out[dstRow + x] = lookup(Int(bit))
                    }
                case .oneBitLE:
                    for x in 0..<width {
                        let bit = (data[srcRow + x / 8] >> UInt8(x & 7)) & 1
                        out[dstRow + x] = lookup(Int(bit))
                    }
                case .eightBitAlpha:
                    // A8: alpha only; premultiplied colour is black.
                    for x in 0..<width { out[dstRow + x] = UInt32(data[srcRow + x]) << 24 }
                case .invalid:
                    break
                }
            }
        }
        return output
    }

    static func minimumStride(format: BitmapFormat, width: Int) -> Int {
        switch format {
        case .oneBitLE, .oneBitBE: (width + 7) / 8
        case .fourBitLE, .fourBitBE: (width + 1) / 2
        case .eightBit, .eightBitAlpha: width
        case .sixteenBit: width * 2
        case .twentyFourBit: width * 3
        case .thirtyTwoBit, .rgba: width * 4
        case .invalid: Int.max
        }
    }

    /// Reads a 1-bpp mask bitmap into a boolean-per-pixel array (top-down).
    public static func decodeMask(_ bitmap: BitmapData) throws(CodecError) -> (width: Int, height: Int, bits: [Bool]) {
        let width = Int(bitmap.width), height = Int(bitmap.height)
        try CodecLimits.check(width: width, height: height)
        let stride = Int(bitmap.stride)
        guard bitmap.format == .oneBitBE || bitmap.format == .oneBitLE else {
            throw .unsupportedType("mask format \(bitmap.format)")
        }
        guard stride >= (width + 7) / 8, bitmap.data.count >= stride * height else { throw .truncated }
        var bits = [Bool](repeating: false, count: width * height)
        let topDown = bitmap.flags.contains(.topDown)
        let base = bitmap.data.startIndex
        for row in 0..<height {
            let src = base + row * stride
            let dst = (topDown ? row : height - 1 - row) * width
            for x in 0..<width {
                let byte = bitmap.data[src + x / 8]
                let bit = bitmap.format == .oneBitBE ? (byte >> (7 - UInt8(x & 7))) & 1 : (byte >> UInt8(x & 7)) & 1
                bits[dst + x] = bit != 0
            }
        }
        return (width, height, bits)
    }
}
