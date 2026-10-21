/// `SPICE_IMAGE_TYPE_LZ4` images: a top-down flag, a SPICE bitmap format, then raw LZ4
/// blocks (each prefixed with a big-endian u32 size) decoded as one stream, so later
/// blocks may refer back into earlier output. Rows are tightly packed (stride = width ×
/// bytes per pixel). The image size comes from the image descriptor.
public enum LZ4ImageDecoder {
    public static func decode(_ data: ArraySlice<UInt8>, width: Int, height: Int) throws(CodecError) -> PixelBuffer {
        try CodecLimits.check(width: width, height: height)
        guard data.count >= 2 else { throw .truncated }
        let topDown = data[data.startIndex] != 0
        let format = data[data.startIndex + 1]
        let bytesPerPixel: Int
        switch format {
        case 6: bytesPerPixel = 2  // 16BIT
        case 7: bytesPerPixel = 3  // 24BIT
        case 8, 9: bytesPerPixel = 4  // 32BIT, RGBA
        default: throw .unsupportedType("lz4 bitmap format \(format)")
        }
        let total = width * height * bytesPerPixel
        var raw = [UInt8]()
        raw.reserveCapacity(total)
        var index = data.startIndex + 2
        while index < data.endIndex {
            guard data.endIndex - index >= 4 else { throw .truncated }
            let size = Int(data[index]) << 24 | Int(data[index + 1]) << 16 | Int(data[index + 2]) << 8 | Int(data[index + 3])
            index += 4
            guard size <= data.endIndex - index else { throw .truncated }
            try LZ4Decoder.decompressAppending(data[index..<(index + size)], into: &raw, limit: total)
            index += size
        }
        guard raw.count == total else { throw .corrupt("lz4 image size \(raw.count) != \(total)") }

        var output = PixelBuffer(width: width, height: height)
        output.hasAlpha = format == 9
        raw.withUnsafeBufferPointer { src in
            output.pixels.withUnsafeMutableBufferPointer { dst in
                for i in 0..<(width * height) {
                    let o = i * bytesPerPixel
                    switch format {
                    case 6:
                        let v = UInt32(src[o]) | UInt32(src[o + 1]) << 8
                        dst[i] = 0xFF00_0000 | expand555(v)
                    case 7:
                        dst[i] = 0xFF00_0000 | UInt32(src[o]) | UInt32(src[o + 1]) << 8 | UInt32(src[o + 2]) << 16
                    case 8:
                        dst[i] = 0xFF00_0000 | UInt32(src[o]) | UInt32(src[o + 1]) << 8 | UInt32(src[o + 2]) << 16
                    default:
                        dst[i] = UInt32(src[o]) | UInt32(src[o + 1]) << 8 | UInt32(src[o + 2]) << 16 | UInt32(src[o + 3]) << 24
                    }
                }
            }
        }
        if !topDown { output.flipVertically() }
        return output
    }

    /// x1r5g5b5 → xRGB8888 with each channel expanded as (c << 3) | (c >> 2).
    @inline(__always)
    static func expand555(_ v: UInt32) -> UInt32 {
        let r = (v >> 10) & 31, g = (v >> 5) & 31, b = v & 31
        return ((r << 3) | (r >> 2)) << 16 | ((g << 3) | (g >> 2)) << 8 | ((b << 3) | (b >> 2))
    }
}

extension LZ4Decoder {
    /// Decodes one LZ4 block, appending to `output`; matches may reach back into bytes
    /// already in `output` (LZ4 streaming / "continue" semantics). Stops at `limit` bytes.
    static func decompressAppending(_ input: ArraySlice<UInt8>, into output: inout [UInt8], limit: Int) throws(CodecError) {
        var i = input.startIndex
        let end = input.endIndex

        func readLength(_ base: Int) throws(CodecError) -> Int {
            var length = base
            guard base == 15 else { return length }
            while true {
                guard i < end else { throw .truncated }
                let byte = input[i]
                i += 1
                length += Int(byte)
                guard length <= limit else { throw .corrupt("lz4 length") }
                if byte != 255 { return length }
            }
        }

        while i < end {
            let token = input[i]
            i += 1
            let literals = try readLength(Int(token >> 4))
            guard literals <= end - i, output.count + literals <= limit else { throw .corrupt("lz4 literals") }
            output.append(contentsOf: input[i..<(i + literals)])
            i += literals
            if i == end { break }
            guard end - i >= 2 else { throw .truncated }
            let offset = Int(input[i]) | Int(input[i + 1]) << 8
            i += 2
            guard offset > 0, offset <= output.count else { throw .corrupt("lz4 offset") }
            let matchLength = try readLength(Int(token & 0x0F)) + 4
            guard output.count + matchLength <= limit else { throw .corrupt("lz4 match") }
            let start = output.count - offset
            for k in 0..<matchLength { output.append(output[start + k]) }
        }
    }
}
