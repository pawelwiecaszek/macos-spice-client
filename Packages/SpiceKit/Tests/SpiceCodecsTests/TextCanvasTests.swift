import Testing
@testable import SpiceCodecs
import SpiceWire

struct TextCanvasTests {
    @Test func bottomUpMsbRowsAndOriginsMatchKnownPixels() throws {
        var image = PixelBuffer(width: 6,height: 5)
        try draw(&image, string([glyph()]))
        #expect(lit(image) == [7,9,14]) // top101, bottom010 at(1,1).
    }

    @Test func overlappingGlyphsAndClipRectanglesFormAUnion() throws {
        var image = PixelBuffer(width: 6,height: 5)
        try draw(&image, string([glyph(),glyph()]), clip: .rects([
            .init(x: 1,y: 1,width: 2,height: 2),.init(x: 1,y: 1,width: 2,height: 2)
        ]))
        #expect(lit(image) == [7,14])
    }

    @Test func backgroundCopyPrecedesOpaqueForeground() throws {
        var image = PixelBuffer(width: 6,height: 5)
        try image.text(string([glyph()]), foreground: .color(0x00FF0000),background: .color(0x000000FF),
                         backgroundArea: .init(x: 1,y: 1,width: 3,height: 2),box: image.bounds,
                         clip: .none,mode: .opPut)
        #expect([7,9,14].allSatisfy { image.pixels[$0] == 0xFFFF0000 })
        #expect([8,13,15].allSatisfy { image.pixels[$0] == 0xFF0000FF })
        #expect(image[0,0] == 0xFF000000)
    }

    @Test func unsupportedFormatsAndModesRejectBeforeBackgroundChanges() {
        for value in [RasterString(format: .a8,glyphs: []),
                      .init(format: .a1,topDown: true,glyphs: [])] {
            var image = PixelBuffer(width: 2,height: 2)
            #expect(throws: TextRasterError.unsupported) {
                try image.text(value,foreground: .color(.max),background: .color(.max),backgroundArea: image.bounds,
                                 box: image.bounds,clip: .none,mode: .opPut)
            }
            #expect(image.pixels.allSatisfy { $0 == 0xFF000000 })
        }
        var image = PixelBuffer(width: 6,height: 5)
        #expect(throws: TextRasterError.unsupported) { try draw(&image,string([glyph()]),mode: .opXor) }
        #expect(lit(image).isEmpty)
    }

    @Test func glyphPaddingDoesNotPaintOutsideTheDeclaredWidth() throws {
        var image = PixelBuffer(width: 6,height: 5)
        let value = RasterGlyph(renderPosition: .init(x: 0,y: 0),origin: .init(x: 0,y: 0),width: 3,height: 1,data: [0xFF])
        try draw(&image,string([value]))
        #expect(lit(image) == [0,1,2])
    }

    @Test func native16BitAndArgbSolidColorsAreOpaque() throws {
        for format: SurfaceFormat in [.x555,.r565,.xRGB32,.argb32] {
            var image = PixelBuffer(width: 6,height: 5)
            let color: UInt32 = format == .r565 ? 0xF800 : format == .x555 ? 0x7C00 : 0x00FF0000
            try image.text(string([glyph()]),foreground: .color(color),background: nil,
                             backgroundArea: .init(x: 0,y: 0,width: 0,height: 0),box: image.bounds,
                             clip: .none,mode: .opPut,format: format)
            #expect([7,9,14].allSatisfy { image.pixels[$0] == 0xFFFF0000 })
        }
    }

    @Test func clipWorkAndInvalidModelsRejectAtomically() {
        var image = PixelBuffer(width: 64,height: 64)
        let large = RasterGlyph(renderPosition: .init(x: 0,y: 0),origin: .init(x: 0,y: 0),
                                width: 64,height: 64,data: Array(repeating: 255,count: 512))
        #expect(throws: TextRasterError.workLimit) {
            try draw(&image,string([large]),clip: .rects(Array(repeating: image.bounds,count: 4096)))
        }
        #expect(lit(image).isEmpty)
        let invalid = RasterGlyph(renderPosition: .init(x: 0,y: 0),origin: .init(x: 0,y: 0),width: 3,height: 2,data: [])
        #expect(throws: TextRasterError.invalidGlyphs) { try draw(&image,string([invalid])) }
        #expect(lit(image).isEmpty)
    }

    private func glyph() -> RasterGlyph {
        .init(renderPosition: .init(x: 2,y: 2),origin: .init(x: -1,y: -1),width: 3,height: 2,data: [0x40,0xA0])
    }
    private func string(_ glyphs: [RasterGlyph]) -> RasterString { .init(format: .a1,glyphs: glyphs) }
    private func draw(_ image: inout PixelBuffer,_ value: RasterString,clip: Clip = .none,mode: Ropd = .opPut) throws {
        try image.text(value,foreground: .color(.max),background: nil,backgroundArea: .init(x: 0,y: 0,width: 0,height: 0),
                         box: image.bounds,clip: clip,mode: mode)
    }
    private func lit(_ image: PixelBuffer) -> [Int] { image.pixels.indices.filter { image.pixels[$0] == .max } }
}
