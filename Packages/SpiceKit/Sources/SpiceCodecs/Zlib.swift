#if canImport(Compression)
import Compression

/// zlib (RFC 1950) inflate for `ZLIB_GLZ_RGB`, via Apple's Compression framework, which
/// handles raw deflate: the 2-byte zlib header and the Adler-32 trailer are stripped.
public enum Zlib {
    public static func inflate(_ data: ArraySlice<UInt8>, expectedSize: Int) throws(CodecError) -> [UInt8] {
        guard expectedSize > 0, expectedSize <= 256 * 1024 * 1024 else { throw .corrupt("zlib size") }
        guard data.count > 6, data[data.startIndex] & 0x0F == 8 else { throw .corrupt("zlib header") }
        let body = data[(data.startIndex + 2)..<(data.endIndex - 4)]
        var output = [UInt8](repeating: 0, count: expectedSize)
        let written = body.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, expectedSize, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw .corrupt("zlib inflate \(written) != \(expectedSize)") }
        return output
    }
}
#endif
