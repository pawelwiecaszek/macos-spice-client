/// `SPICE_IMAGE_TYPE_GLZ_RGB`: LZ-style compression whose back-references may point into
/// earlier images of a shared window (the "global dictionary"), identified by image id.
///
/// Written from a prose description of the format (see `FORMAT` notes below) and verified
/// against images captured from a real spice-server, not derived from its source code.
///
/// Format notes: a 33-byte big-endian header (magic `0x20205A4C`, version, type byte with
/// top-down flag in bit 4, width, height, stride, u64 image id, u32 window head distance),
/// then control bytes: < 32 introduces C+1 literals; otherwise a match whose length,
/// offset and image distance are packed into the control byte and up to a few more bytes.
/// RGBA images carry a second, alpha-only pass with the same scheme.
public struct GLZDecoder: Sendable {
    /// Decoded images kept for cross-image references, in stream order (32-bit pixels).
    private var window: [UInt64: [UInt32]] = [:]
    private var windowPixels = 0
    /// Upper bound for the window (the server's dictionary is sized from what the client
    /// announced in DISPLAY_INIT; this only guards against a misbehaving server).
    public let maxWindowPixels: Int

    static let magic: UInt32 = 0x2020_5A4C
    static let headerSize = 33

    public init(maxWindowPixels: Int = 64 * 1024 * 1024) {
        self.maxWindowPixels = maxWindowPixels
    }

    public var storedImageCount: Int { window.count }

    public mutating func reset() {
        window.removeAll()
        windowPixels = 0
    }

    private enum Kind {
        case rgb16, rgb24, rgb32, rgba
    }

    public mutating func decode(_ data: ArraySlice<UInt8>) throws(CodecError) -> PixelBuffer {
        var reader = Reader(data)
        guard data.count >= Self.headerSize else { throw .truncated }
        guard try reader.be32() == Self.magic else { throw .badMagic }
        let version = try reader.be32()
        guard version == 0x0001_0001 else { throw .unsupportedVersion(version) }
        let typeByte = try reader.byte()
        let topDown = typeByte & 0x10 != 0
        let kind: Kind
        switch typeByte & 0x0F {
        case 6: kind = .rgb16
        case 7: kind = .rgb24
        case 8: kind = .rgb32
        case 9: kind = .rgba
        case let other: throw .unsupportedType("glz image type \(other)")
        }
        let width = Int(try reader.be32())
        let height = Int(try reader.be32())
        _ = try reader.be32()  // stride: rows are decoded as width pixels
        let id = UInt64(try reader.be32()) << 32 | UInt64(try reader.be32())
        let windowHeadDistance = UInt64(try reader.be32())
        try CodecLimits.check(width: width, height: height)
        let count = width * height

        var pixels = [UInt32](repeating: 0, count: count)
        try decodePass(&reader, into: &pixels, id: id, unit: kind == .rgb16 ? .rgb16 : .rgb24, lengthBias: kind == .rgb16 ? 1 : 0)
        if kind == .rgba {
            try decodePass(&reader, into: &pixels, id: id, unit: .alpha, lengthBias: 2)
        }

        remember(pixels, id: id, headDistance: windowHeadDistance)

        var output = PixelBuffer(width: width, height: height, pixels: pixels, hasAlpha: kind == .rgba)
        if kind != .rgba {
            output.pixels.withUnsafeMutableBufferPointer { buffer in
                for i in buffer.indices { buffer[i] |= 0xFF00_0000 }
            }
        }
        if !topDown { output.flipVertically() }
        return output
    }

    private enum Unit {
        case rgb24  // 3 bytes B G R
        case rgb16  // 2 bytes, big-endian x1r5g5b5
        case alpha  // 1 byte, written to the top byte only
    }

    private func decodePass(_ reader: inout Reader, into pixels: inout [UInt32], id: UInt64,
                            unit: Unit, lengthBias: Int) throws(CodecError) {
        let total = pixels.count
        var op = 0
        while op < total {
            let control = Int(try reader.byte())
            if control < 32 {
                let run = control + 1
                guard op + run <= total else { throw .corrupt("glz literal overrun") }
                for _ in 0..<run {
                    switch unit {
                    case .rgb24:
                        let b = UInt32(try reader.byte()), g = UInt32(try reader.byte()), r = UInt32(try reader.byte())
                        pixels[op] = b | g << 8 | r << 16
                    case .rgb16:
                        let hi = UInt32(try reader.byte()), lo = UInt32(try reader.byte())
                        pixels[op] = LZ4ImageDecoder.expand555(hi << 8 | lo)
                    case .alpha:
                        pixels[op] = (pixels[op] & 0x00FF_FFFF) | UInt32(try reader.byte()) << 24
                    }
                    op += 1
                }
                continue
            }

            // Match.
            var length = control >> 5
            let longForm = (control >> 4) & 1 == 1
            var offset = control & 0x0F
            if length == 7 {
                while true {
                    let extra = Int(try reader.byte())
                    length += extra
                    guard length <= total else { throw .corrupt("glz length") }
                    if extra != 255 { break }
                }
            }
            offset += Int(try reader.byte()) << 4
            let x = Int(try reader.byte())
            let distanceBytes = x >> 6
            var distance = 0
            if !longForm {
                distance = x & 0x3F
                for i in 0..<distanceBytes { distance += Int(try reader.byte()) << (6 + 8 * i) }
            } else {
                offset += (x & 0x1F) << 12
                for i in 0..<distanceBytes { distance |= Int(try reader.byte()) << (8 * i) }
                if (x >> 5) & 1 == 1 { offset += Int(try reader.byte()) << 17 }
            }
            length += lengthBias
            guard length > 0, op + length <= total else { throw .corrupt("glz match overrun") }

            if distance == 0 {
                offset += 1
                guard offset <= op else { throw .corrupt("glz offset") }
                let source = op - offset
                for k in 0..<length {
                    let value = pixels[source + k]  // may overlap: copy forward
                    pixels[op + k] = unit == .alpha ? (pixels[op + k] & 0x00FF_FFFF) | (value & 0xFF00_0000) : value
                }
            } else {
                guard UInt64(distance) <= id, let reference = window[id - UInt64(distance)] else {
                    throw .corrupt("glz reference to unknown image")
                }
                guard offset + length <= reference.count else { throw .corrupt("glz cross-image overrun") }
                for k in 0..<length {
                    let value = reference[offset + k]
                    pixels[op + k] = unit == .alpha ? (pixels[op + k] & 0x00FF_FFFF) | (value & 0xFF00_0000) : value
                }
            }
            op += length
        }
    }

    /// Stores the image and drops those that left the encoder's window.
    private mutating func remember(_ pixels: [UInt32], id: UInt64, headDistance: UInt64) {
        if let old = window[id] { windowPixels -= old.count }
        window[id] = pixels
        windowPixels += pixels.count
        if headDistance <= id {
            let oldest = id - headDistance
            for key in window.keys where key < oldest {
                windowPixels -= window.removeValue(forKey: key)?.count ?? 0
            }
        }
        // Safety net against a misbehaving server: forget the oldest images.
        while windowPixels > maxWindowPixels, let oldestKey = window.keys.min(), oldestKey != id {
            windowPixels -= window.removeValue(forKey: oldestKey)?.count ?? 0
        }
    }

    private struct Reader {
        let data: ArraySlice<UInt8>
        var index: Int

        init(_ data: ArraySlice<UInt8>) {
            self.data = data
            index = data.startIndex
        }

        @inline(__always)
        mutating func byte() throws(CodecError) -> UInt8 {
            guard index < data.endIndex else { throw .truncated }
            defer { index += 1 }
            return data[index]
        }

        mutating func be32() throws(CodecError) -> UInt32 {
            UInt32(try byte()) << 24 | UInt32(try byte()) << 16 | UInt32(try byte()) << 8 | UInt32(try byte())
        }
    }
}
