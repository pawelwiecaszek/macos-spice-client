import Testing
@testable import SpiceWire

struct DrawTextTests {
    @Test func inlineGlyphRecordsKeepPackedRowsAndMetadata() throws {
        for (flags, data): (UInt8, [UInt8]) in [(1,[0x40,0xA0]), (10,[0x12,0x30,0x45,0x60]),
                                              (4,[1,2,3,4,5,6])] {
            let decoded = try DrawText(decoding: fixture(flags: flags, data: data, count: 2))
            #expect(decoded.string.flags == flags)
            #expect(decoded.string.glyphs.count == 2)
            #expect(decoded.string.glyphs[0].data == data)
            #expect(try decoded.string.glyphs[0].bounds() == Rect(x: 1,y: 1,width: 3,height: 2))
            #expect(decoded.foregroundBrush == .solid(0xFF0000))
            #expect(decoded.backMode == .opXor)
            try decoded.string.validate()
        }
    }

    @Test func truncatedOffsetsAndInvalidFlagsReject() {
        let bytes = fixture()
        for length in 0..<bytes.count {
            #expect(throws: WireError.self) { _ = try DrawText(decoding: Array(bytes.prefix(length))) }
        }
        for flags: UInt8 in [0,3,5,7,8,16,255] {
            #expect(throws: WireError.self) { _ = try DrawText(decoding: fixture(flags: flags)) }
        }
        for pointer: UInt32 in [0,1,54,.max] {
            var invalid = bytes, writer = ByteWriter(); writer.writeU32(pointer)
            invalid.replaceSubrange(21..<25, with: writer.bytes)
            #expect(throws: WireError.self) { _ = try DrawText(decoding: invalid) }
        }
    }

    @Test func directModelsAndDecodedBoundsHaveTheSameLimits() {
        let position = Point(x: .max,y: 0), origin = Point(x: 1,y: 0)
        let invalid = RasterGlyph(renderPosition: position, origin: origin, width: 0,height: 0,data: [])
        #expect(throws: WireError.self) { try RasterString(format: .a1,glyphs: [invalid]).validate() }
        for width in [-1,16_385,Int.max] {
            let glyph = RasterGlyph(renderPosition: .init(x: 0,y: 0),origin: .init(x: 0,y: 0),width: width,height: 1,data: [])
            #expect(throws: WireError.self) { try RasterString(format: .a1,glyphs: [glyph]).validate() }
        }
        var invalidBytes = fixture(), writer = ByteWriter(); writer.writeI32(.max); writer.writeI32(.max)
        invalidBytes.replaceSubrange(58..<66, with: writer.bytes)
        // Origin(-1,-1) still leaves width3 beyond Int32.max.
        #expect(throws: WireError.self) { _ = try DrawText(decoding: invalidBytes) }
        var tooMany = fixture(), count = ByteWriter(); count.writeU16(4097)
        tooMany.replaceSubrange(55..<57, with: count.bytes)
        #expect(throws: WireError.self) { _ = try DrawText(decoding: tooMany) }
        var tooLarge = fixture(), dimensions = ByteWriter()
        dimensions.writeU16(16_384); dimensions.writeU16(513)
        tooLarge.replaceSubrange(74..<78, with: dimensions.bytes)
        #expect(throws: WireError.limitExceeded("text glyph pixels")) { _ = try DrawText(decoding: tooLarge) }
        let oversized = RasterGlyph(renderPosition: .init(x: 0,y: 0),origin: .init(x: 0,y: 0),
                                    width: 16_384,height: 513,data: [])
        #expect(throws: WireError.limitExceeded("text glyph pixels")) {
            try RasterString(format: .a1,glyphs: [oversized]).validate()
        }
    }

    @Test func emptyAndZeroExtentStringsAreBoundedValidModels() throws {
        try RasterString(format: .a1,glyphs: []).validate()
        let glyph = RasterGlyph(renderPosition: .init(x: 0,y: 0),origin: .init(x: 0,y: 0),width: 0,height: 4,data: [])
        try RasterString(format: .a8,glyphs: [glyph]).validate()
    }

    private func fixture(flags: UInt8 = 1, data: [UInt8] = [0x40,0xA0], count: UInt16 = 1) -> [UInt8] {
        var writer = ByteWriter()
        writer.writeU32(0)
        for value: Int32 in [0,0,5,6] { writer.writeI32(value) }
        writer.writeU8(0); writer.writeU32(55)
        for value: Int32 in [0,0,5,6] { writer.writeI32(value) }
        writer.writeU8(1); writer.writeU32(0xFF0000)
        writer.writeU8(1); writer.writeU32(0x0000FF)
        writer.writeU16(Ropd.opPut.rawValue); writer.writeU16(Ropd.opXor.rawValue)
        writer.writeU16(count); writer.writeU8(flags)
        for _ in 0..<count {
            for value: Int32 in [2,2,-1,-1] { writer.writeI32(value) }
            writer.writeU16(3); writer.writeU16(2); writer.writeBytes(data)
        }
        return writer.bytes
    }
}
