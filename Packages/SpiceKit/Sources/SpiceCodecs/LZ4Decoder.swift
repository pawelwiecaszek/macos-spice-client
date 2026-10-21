/// LZ4 *block* format decoder (no frame header), as used by spicevmc
/// `COMPRESSED_DATA` and `SPICE_IMAGE_TYPE_LZ4`. Written from the public LZ4 block
/// format description; safe against hostile input.
public enum LZ4Decoder {
    public static func decompress(_ input: ArraySlice<UInt8>, uncompressedSize: Int) throws(CodecError) -> [UInt8] {
        guard uncompressedSize >= 0, uncompressedSize <= 256 * 1024 * 1024 else {
            throw .tooLarge(width: uncompressedSize, height: 1)
        }
        var output = [UInt8]()
        output.reserveCapacity(uncompressedSize)
        var i = input.startIndex
        let end = input.endIndex

        @inline(__always)
        func readLength(_ base: Int) throws(CodecError) -> Int {
            var length = base
            guard base == 15 else { return length }
            while true {
                guard i < end else { throw .truncated }
                let byte = input[i]
                i += 1
                length += Int(byte)
                guard length <= uncompressedSize else { throw .corrupt("lz4 length") }
                if byte != 255 { return length }
            }
        }

        while i < end {
            let token = input[i]
            i += 1
            let literals = try readLength(Int(token >> 4))
            guard literals <= end - i, output.count + literals <= uncompressedSize else { throw .corrupt("lz4 literals") }
            output.append(contentsOf: input[i..<(i + literals)])
            i += literals
            if i == end { break }  // last sequence carries literals only

            guard end - i >= 2 else { throw .truncated }
            let offset = Int(input[i]) | Int(input[i + 1]) << 8
            i += 2
            guard offset > 0, offset <= output.count else { throw .corrupt("lz4 offset") }
            let matchLength = try readLength(Int(token & 0x0F)) + 4
            guard output.count + matchLength <= uncompressedSize else { throw .corrupt("lz4 match") }
            let start = output.count - offset
            for k in 0..<matchLength { output.append(output[start + k]) }  // may overlap
        }
        guard output.count == uncompressedSize else { throw .corrupt("lz4 size \(output.count) != \(uncompressedSize)") }
        return output
    }
}
