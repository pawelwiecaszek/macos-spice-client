import Testing
@testable import SpiceWire

struct DrawStrokeTests {
    @Test func packedPathAndOptionalStylesUseIndependentOffsets() throws {
        let plain = try DrawStroke(decoding: payload())
        #expect(plain.path.segments.count == 1)
        #expect(plain.path.segments[0].points[1] == StrokePoint(x: 64, y: 32))
        #expect(plain.brush == .solid(0x1234_5678))
        #expect(plain.foreMode == .opPut)
        #expect(!plain.attributes.isStyled)
        let styled = try DrawStroke(decoding: payload(style: [16, 32]))
        #expect(styled.attributes.isStyled)
        #expect(styled.attributes.startsWithGap)
        #expect(styled.attributes.style == [16, 32])
        #expect(styled.path == plain.path)
    }

    @Test func allTruncatedPrefixesReject() {
        let bytes = payload()
        for count in 0..<bytes.count {
            #expect(throws: WireError.self) { _ = try DrawStroke(decoding: Array(bytes.prefix(count))) }
        }
    }

    @Test func invalidOffsetsFlagsAndCountsRejectBeforeLargeAllocation() {
        for pointer: UInt32 in [0, 1, .max] {
            var bytes = payload(); patch(&bytes, at: 21, value: pointer)
            #expect(throws: WireError.self) { _ = try DrawStroke(decoding: bytes) }
        }
        var bytes = payload(); bytes[25] = 4
        #expect(throws: WireError.self) { _ = try DrawStroke(decoding: bytes) }
        bytes = payload(); bytes[39] = 128 // path segment flag
        #expect(throws: WireError.self) { _ = try DrawStroke(decoding: bytes) }
        bytes = payload(); patch(&bytes, at: 35, value: 4097)
        #expect(throws: WireError.limitExceeded("stroke segments")) { _ = try DrawStroke(decoding: bytes) }
        bytes = payload(); patch(&bytes, at: 40, value: 65_537)
        #expect(throws: WireError.limitExceeded("stroke points")) { _ = try DrawStroke(decoding: bytes) }
        bytes = payload(style: [16, 0])
        #expect(throws: WireError.self) { _ = try DrawStroke(decoding: bytes) }
    }

    @Test func pathStateAndCubicControlGroupsAreValidated() {
        let point = StrokePoint(x: 0, y: 0)
        #expect(throws: WireError.self) { try StrokePath(segments: [.init(flags: .end, points: [point])]).validate() }
        #expect(throws: WireError.self) { try StrokePath(segments: [.init(flags: [.begin, .close], points: [point])]).validate() }
        #expect(throws: WireError.self) { try StrokePath(segments: [.init(flags: [.begin, .bezier], points: [point, point])]).validate() }
        #expect(throws: WireError.self) { try StrokePath(segments: [.init(flags: .begin, points: [])]).validate() }
        #expect(throws: Never.self) { try StrokePath(segments: [.init(flags: [.begin, .end, .bezier], points: [point, point, point, point])]).validate() }
    }

    @Test func fixedCoordinatesRoundHalfDownWithoutOverflow() {
        #expect(StrokePoint(x: 8, y: 9).rounded == Point(x: 0, y: 1))
        #expect(StrokePoint(x: -8, y: -7).rounded == Point(x: -1, y: 0))
        #expect(StrokePoint(x: .min, y: .max).rounded == Point(x: -134_217_728, y: 134_217_728))
    }

    private func payload(style: [Int32] = []) -> [UInt8] {
        var writer = ByteWriter()
        writer.writeU32(0)
        writer.writeI32(0); writer.writeI32(0); writer.writeI32(3); writer.writeI32(5); writer.writeU8(0)
        writer.writeU32(style.isEmpty ? 35 : 40)
        writer.writeU8(style.isEmpty ? 0 : 12)
        if !style.isEmpty { writer.writeU8(UInt8(style.count)); writer.writeU32(0) }
        writer.writeU8(1); writer.writeU32(0x1234_5678)
        writer.writeU16(Ropd.opPut.rawValue); writer.writeU16(0)
        writer.writeU32(1); writer.writeU8(3); writer.writeU32(2)
        writer.writeI32(0); writer.writeI32(0); writer.writeI32(64); writer.writeI32(32)
        var bytes = writer.bytes
        if !style.isEmpty {
            patch(&bytes, at: 27, value: UInt32(bytes.count))
            var values = ByteWriter(); for value in style { values.writeI32(value) }
            bytes += values.bytes
        }
        return bytes
    }

    private func patch(_ bytes: inout [UInt8], at offset: Int, value: UInt32) {
        var writer = ByteWriter(); writer.writeU32(value)
        bytes.replaceSubrange(offset..<(offset + 4), with: writer.bytes)
    }
}
