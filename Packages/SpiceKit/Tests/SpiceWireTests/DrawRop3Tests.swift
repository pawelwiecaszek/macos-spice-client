import Testing
@testable import SpiceWire

struct DrawRop3Tests {
    @Test func decodesPackedRopAndScaleBytesAndRelativeSourcePointer() throws {
        let draw = try DrawRop3(decoding: payload())
        #expect(draw.base.surfaceID == 7)
        #expect(draw.sourceArea == Rect(x: 1, y: 2, width: 3, height: 4))
        #expect(draw.brush == .solid(0x1234_5678))
        #expect(draw.rop == 0xCA)
        #expect(draw.scaleMode == .nearest)
        #expect(draw.mask.inverted)
        #expect(draw.mask.position == Point(x: 2, y: 3))
        #expect(draw.mask.bitmap == nil)
        #expect(draw.source?.payload == .surface(id: 9))
    }

    @Test func everyTruncatedPrefixRejectsWithoutReadingPastPayload() {
        let bytes = payload()
        for end in 0..<bytes.count {
            #expect(throws: WireError.self) { _ = try DrawRop3(decoding: Array(bytes.prefix(end))) }
        }
    }

    @Test func invalidScaleAndImageOffsetReject() {
        var bytes = payload()
        bytes[47] = 255
        #expect(throws: WireError.self) { _ = try DrawRop3(decoding: bytes) }
        bytes = payload()
        bytes.replaceSubrange(21..<25, with: [255, 255, 255, 255])
        #expect(throws: WireError.self) { _ = try DrawRop3(decoding: bytes) }
    }

    @Test func missingSourceAndUnknownMaskFlagsReject() {
        var bytes = payload()
        bytes.replaceSubrange(21..<25, with: [0, 0, 0, 0])
        #expect(throws: WireError.self) { _ = try DrawRop3(decoding: bytes) }
        bytes = payload(); bytes[48] = 2
        #expect(throws: WireError.self) { _ = try DrawRop3(decoding: bytes) }
    }

    private func payload() -> [UInt8] {
        var writer = ByteWriter()
        writer.writeU32(7)
        rect(&writer, x: 0, y: 0, width: 3, height: 4)
        writer.writeU8(0) // no clip
        writer.writeU32(61) // appended source image
        rect(&writer, x: 1, y: 2, width: 3, height: 4)
        writer.writeU8(1); writer.writeU32(0x1234_5678) // solid brush
        writer.writeU8(0xCA); writer.writeU8(1)
        writer.writeU8(1); writer.writeI32(2); writer.writeI32(3); writer.writeU32(0)
        writer.writeU64(17); writer.writeU8(ImageType.surface.rawValue); writer.writeU8(0)
        writer.writeU32(4); writer.writeU32(6); writer.writeU32(9)
        return writer.bytes
    }

    private func rect(_ writer: inout ByteWriter, x: Int32, y: Int32, width: Int32, height: Int32) {
        writer.writeI32(y); writer.writeI32(x); writer.writeI32(y + height); writer.writeI32(x + width)
    }
}
