/// `SPICE_MSG_DISPLAY_DRAW_ROP3`: a ternary pattern/source/destination raster operation.
/// Packed layout: spice-common@58d375e5eadc6fb9e587e99fd81adcb95d01e8d6,
/// spice.proto:847–857. Image pointers are UInt32 message-relative offsets.
public struct DrawRop3: Sendable, Hashable {
    public let base: DisplayBase
    public let source: Image?
    public let sourceArea: Rect
    public let brush: Brush
    /// Truth-table bit index is `(patternBit << 2) | (sourceBit << 1) | destinationBit`.
    public let rop: UInt8
    public let scaleMode: ScaleMode
    public let mask: QMask

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var reader = ByteReader(bytes)
        base = try DisplayBase.decode(&reader)
        let pointer = try reader.readU32()
        guard let image = try Image.decode(at: pointer, in: reader) else {
            throw .invalidValue("ROP3 source image")
        }
        source = image
        sourceArea = try Rect.decode(&reader)
        brush = try Brush.decode(&reader)
        if case .none = brush { throw .invalidValue("ROP3 brush") }
        rop = try reader.readU8()
        guard let scale = ScaleMode(rawValue: try reader.readU8()) else {
            throw .invalidValue("ROP3 scale mode")
        }
        scaleMode = scale
        var maskReader = reader
        guard try maskReader.readU8() & ~UInt8(1) == 0 else { throw .invalidValue("ROP3 mask flags") }
        mask = try QMask.decode(&reader)
    }
}
