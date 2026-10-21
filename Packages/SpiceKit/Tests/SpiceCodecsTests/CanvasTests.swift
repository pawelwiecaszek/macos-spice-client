import Testing
@testable import SpiceCodecs
import SpiceWire

@Suite("Canvas")
struct CanvasTests {
    func surface(_ width: Int = 8, _ height: Int = 6) -> PixelBuffer {
        PixelBuffer(width: width, height: height, fill: 0xFF00_0000)
    }

    @Test func fillClipsToSurfaceAndClipRects() {
        var s = surface()
        let dirty = s.fill(box: Rect(x: -2, y: -2, width: 6, height: 6),
                           clip: .rects([Rect(x: 1, y: 1, width: 2, height: 2), Rect(x: 0, y: 3, width: 1, height: 1)]),
                           source: .color(0x00FF_0000))
        #expect(dirty == Rect(x: 0, y: 1, width: 3, height: 3))
        #expect(s[1, 1] == 0xFFFF_0000)
        #expect(s[2, 2] == 0xFFFF_0000)
        #expect(s[0, 3] == 0xFFFF_0000)
        #expect(s[0, 0] == 0xFF00_0000)
        #expect(s[3, 3] == 0xFF00_0000)
    }

    @Test func ropXorAndInvert() {
        var s = surface(2, 1)
        s.fill(box: s.bounds, clip: .none, source: .color(0x0000_00FF))
        s.fill(box: s.bounds, clip: .none, source: .color(0x0000_000F), rop: .opXor)
        #expect(s[0, 0] == 0xFF00_00F0)
        s.applyUnary(box: s.bounds, clip: .none, rop: .opInvers)
        #expect(s[1, 0] == 0xFFFF_FF0F)
        s.applyUnary(box: s.bounds, clip: .none, rop: .opBlackness)
        #expect(s[1, 0] == 0xFF00_0000)
    }

    @Test func copyWithScaling() {
        var source = PixelBuffer(width: 2, height: 1)
        source[0, 0] = 0xFF11_1111
        source[1, 0] = 0xFF22_2222
        var s = surface(4, 2)
        s.copy(from: source, sourceArea: source.bounds, box: Rect(x: 0, y: 0, width: 4, height: 2), clip: .none)
        #expect(s[0, 0] == 0xFF11_1111 && s[1, 1] == 0xFF11_1111)
        #expect(s[2, 0] == 0xFF22_2222 && s[3, 1] == 0xFF22_2222)
    }

    @Test func copyBitsHandlesOverlapLikeScrolling() {
        var s = surface(1, 5)
        for y in 0..<5 { s[0, y] = 0xFF00_0000 | UInt32(y) }
        // Scroll up by one: copy rows 1...4 to rows 0...3.
        s.copyBits(sourcePosition: Point(x: 0, y: 1), box: Rect(x: 0, y: 0, width: 1, height: 4), clip: .none)
        #expect((0..<4).map { s[0, $0] & 0xFF } == [1, 2, 3, 4])
        // Scroll down by two.
        s.copyBits(sourcePosition: Point(x: 0, y: 0), box: Rect(x: 0, y: 2, width: 1, height: 3), clip: .none)
        #expect((0..<5).map { s[0, $0] & 0xFF } == [1, 2, 1, 2, 3])
    }

    @Test func transparentSkipsColorKey() {
        var source = PixelBuffer(width: 2, height: 1)
        source[0, 0] = 0xFF00_FF00
        source[1, 0] = 0xFF12_3456
        var s = surface(2, 1)
        s.transparentCopy(from: source, sourceArea: source.bounds, box: s.bounds, clip: .none, colorKey: 0x00FF00)
        #expect(s[0, 0] == 0xFF00_0000)
        #expect(s[1, 0] == 0xFF12_3456)
    }

    @Test func alphaBlendHalf() {
        var source = PixelBuffer(width: 1, height: 1, fill: 0xFFFF_FFFF)
        source.hasAlpha = true
        var s = surface(1, 1)
        s.alphaBlend(from: source, sourceArea: source.bounds, box: s.bounds, clip: .none, alpha: 128, sourceHasAlpha: true)
        let red = (s[0, 0] >> 16) & 0xFF
        #expect((127...129).contains(red))
    }

    @Test func maskLimitsFill() {
        var s = surface(2, 1)
        let mask = DrawMask(width: 2, height: 1, bits: [true, false], inverted: false, origin: Point(x: 0, y: 0))
        s.fill(box: s.bounds, clip: .none, source: .color(0xFFFFFF), mask: mask)
        #expect(s[0, 0] == 0xFFFF_FFFF)
        #expect(s[1, 0] == 0xFF00_0000)
    }

    @Test func bitmapFormats() throws {
        let palette = Palette(unique: 1, entries: [0x000000, 0xFF0000, 0x00FF00, 0x0000FF])
        // 2x2 8-bit, bottom-up: first stored row is the bottom row.
        let bitmap = BitmapData(format: .eightBit, flags: [], width: 2, height: 2, stride: 4,
                                palette: .inline(palette), data: [1, 2, 0, 0, 3, 0, 0, 0][...])
        let image = try BitmapDecoder.decode(bitmap, palette: palette)
        #expect(image[0, 0] == 0xFF00_00FF)  // top-left = second stored row, index 3
        #expect(image[0, 1] == 0xFFFF_0000)
        #expect(image[1, 1] == 0xFF00_FF00)

        let rgb16 = BitmapData(format: .sixteenBit, flags: .topDown, width: 1, height: 1, stride: 2,
                               palette: .none, data: [0x00, 0x7C][...])  // pure red in x555
        #expect(try BitmapDecoder.decode(rgb16, palette: nil)[0, 0] == 0xFFFF_0000)

        let mono = BitmapData(format: .oneBitBE, flags: .topDown, width: 3, height: 1, stride: 1,
                              palette: .inline(palette), data: [0b1010_0000][...])
        let monoImage = try BitmapDecoder.decode(mono, palette: palette)
        #expect(monoImage.pixels == [0xFFFF_0000, 0xFF00_0000, 0xFFFF_0000])
    }

    @Test func bitmapRejectsShortData() {
        let bitmap = BitmapData(format: .thirtyTwoBit, flags: [], width: 4, height: 4, stride: 16,
                                palette: .none, data: [0, 0, 0][...])
        #expect(throws: CodecError.truncated) { try BitmapDecoder.decode(bitmap, palette: nil) }
    }
}
