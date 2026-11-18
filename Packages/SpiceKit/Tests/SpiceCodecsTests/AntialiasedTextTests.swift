import Foundation
import Testing
@testable import SpiceCodecs
import SpiceWire

struct AntialiasedTextTests {
    @Test func a4MaskedPatternsMatchPixmanOverFixtures() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/text-a4-over.txt")
        let lines = try String(contentsOf: fixture,encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 160)
        for line in lines {
            let fields = line.split(separator: " ")
            let source = try #require(UInt32(fields[1],radix: 16))
            let destination = try #require(UInt32(fields[2],radix: 16))
            let alpha = try #require(UInt8(fields[3]))
            let expected = try #require(UInt32(fields[4],radix: 16))
            let pattern = PixelBuffer(width: 1,height: 1,pixels: [source],hasAlpha: true)
            var image = PixelBuffer(width: 1,height: 1,fill: destination,hasAlpha: true)
            try paint(&image,glyph(data: [alpha],width: 1,height: 1),
                      foreground: .pattern(pattern,origin: .init(x: 0,y: 0)),
                      format: fields[0] == "argb" ? .argb32 : .xRGB32)
            #expect(image[0,0] == expected,"Oracle: \(line)")
        }
    }

    @Test func clippedPatternsKeepFullMaskAnchorAndPremultipliedAlpha() throws {
        let pattern = PixelBuffer(width: 2,height: 2,
                                  pixels: [0xFFFF0000,0x80008000,0xFF0000FF,0x40400000],hasAlpha: true)
        let value = glyph(data: [0xFF,0x81,0xF8,0x10],width: 4,height: 2,x: 5,y: 3)
        let expected: [UInt32] = [0xFF542531,0xFF1018A0,0xFF232F3F,0xFF203040,
                                  0xFF119122,0xFFF20304,0xFF186430,0xFF2E2D3C]
        for clipped in [false,true] {
            var image = PixelBuffer(width: 12,height: 8,fill: 0xFF203040,hasAlpha: true)
            try paint(&image,value,foreground: .pattern(pattern,origin: .init(x: 1,y: -1)),
                      clip: clipped ? .rects([.init(x: 6,y: 0,width: 6,height: 8)]) : .none)
            for y in 0..<2 {
                for x in 0..<4 {
                    #expect(image[x+5,y+3] == (clipped && x == 0 ? 0xFF203040 : expected[y*4+x]))
                }
            }
        }
    }

    @Test func a4NibblesUseMaximumCoverageInsteadOfRepeatedBlending() throws {
        let low = glyph(data: [0x20],width: 1,height: 1)
        let high = glyph(data: [0x80],width: 1,height: 1)
        var image = PixelBuffer(width: 1,height: 1)
        try image.text(.init(format: .a4,glyphs: [low,high,high]),foreground: .color(.max),background: nil,
                       backgroundArea: image.bounds,box: image.bounds,clip: .none,mode: .opPut)
        #expect(image[0,0] == 0xFF808080)
        try paint(&image,glyph(data: [0xF0],width: 1,height: 1),foreground: .color(.max))
        #expect(image[0,0] == 0xFFF8F8F8,"A4 maximum is 240, so prior destination still contributes")
    }

    @Test func backgroundPatternsUseDestinationCoordinatesAndCopyAlpha() throws {
        let pattern = PixelBuffer(width: 2,height: 1,pixels: [0x80008000,0xFFFF0000],hasAlpha: true)
        var image = PixelBuffer(width: 4,height: 1,hasAlpha: true)
        try image.text(.init(format: .a4,glyphs: []),foreground: nil,
                       background: .pattern(pattern,origin: .init(x: 1,y: 0)),
                       backgroundArea: .init(x: 1,y: 0,width: 3,height: 1),box: image.bounds,
                       clip: .none,mode: .opPut,format: .argb32)
        #expect(image.pixels == [0xFF000000,0x80008000,0xFFFF0000,0x80008000])
    }

    @Test func patternSnapshotsAndOpaqueImagesPreserveOriginalPixels() throws {
        var image = PixelBuffer(width: 2,height: 1,pixels: [0x00FF0000,0x000000FF],hasAlpha: false)
        let snapshot = image
        let value = RasterString(format: .a1,glyphs: [glyph(data: [0xC0],width: 2,height: 1)])
        try image.text(value,foreground: .pattern(snapshot,origin: .init(x: 1,y: 0)),background: nil,
                       backgroundArea: image.bounds,box: image.bounds,clip: .none,mode: .opPut)
        #expect(image.pixels == [0xFF0000FF,0xFFFF0000])
    }

    @Test func unsupportedNativeAntialiasAndInvalidPatternsAreAtomic() {
        var image = PixelBuffer(width: 1,height: 1)
        #expect(throws: TextRasterError.unsupported) {
            try paint(&image,glyph(data: [0xF0],width: 1,height: 1),foreground: .color(0xF800),format: .r565)
        }
        #expect(throws: TextRasterError.invalidGlyphs) {
            try paint(&image,glyph(data: [0xF0],width: 1,height: 1),
                      foreground: .pattern(PixelBuffer(width: 0,height: 0),origin: .init(x: 0,y: 0)))
        }
        #expect(image[0,0] == 0xFF000000)
    }

    private func glyph(data: [UInt8],width: Int,height: Int,x: Int32 = 0,y: Int32 = 0) -> RasterGlyph {
        .init(renderPosition: .init(x: x,y: y),origin: .init(x: 0,y: 0),width: width,height: height,data: data)
    }
    private func paint(_ image: inout PixelBuffer,_ value: RasterGlyph,foreground: FillSource,
                       clip: Clip = .none,format: SurfaceFormat = .argb32) throws {
        try image.text(.init(format: .a4,glyphs: [value]),foreground: foreground,background: nil,
                       backgroundArea: image.bounds,box: image.bounds,clip: clip,mode: .opPut,format: format)
    }
}
