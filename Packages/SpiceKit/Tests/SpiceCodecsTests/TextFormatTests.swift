import Foundation
import Testing
@testable import SpiceCodecs
import SpiceWire

struct TextFormatTests {
    @Test func everyGlyphFormatHonorsItsDeclaredRowOrder() throws {
        let cases: [(GlyphFormat,[UInt8],[UInt32])] = [
            (.a1,[0x40,0xA0],[255,0,255,0,255,0]),
            (.a4,[0x14,0xF0,0xF8,0x00],[240,128,0,16,64,240]),
            (.a8,[16,64,240,255,128,0],[255,128,0,16,64,240])
        ]
        for (format,bottomUp,expected) in cases {
            let stride = (3 * format.bitsPerPixel + 7) / 8
            for topDown in [false,true] {
                let data = topDown ? Array(bottomUp.suffix(stride)) + Array(bottomUp.prefix(stride)) : bottomUp
                var image = PixelBuffer(width: 3,height: 2)
                try image.text(string(format: format,data: data,width: 3,height: 2,topDown: topDown),
                               foreground: .color(.max),background: nil,backgroundArea: image.bounds,
                               box: image.bounds,clip: .none,mode: .opPut)
                #expect(image.pixels == expected.map { 0xFF000000 | $0 * 0x010101 })
            }
        }
    }

    @Test func a8UsesExactCoverageAndMaximumOverlap() throws {
        let first = string(format: .a8,data: [129],width: 1,height: 1).glyphs[0]
        let second = string(format: .a8,data: [130],width: 1,height: 1).glyphs[0]
        var image = PixelBuffer(width: 1,height: 1)
        try image.text(.init(format: .a8,glyphs: [first,second]),foreground: .color(.max),background: nil,
                       backgroundArea: image.bounds,box: image.bounds,clip: .none,mode: .opPut)
        #expect(image[0,0] == 0xFF828282)
    }

    @Test func nativePatternOverMatchesPixmanFixtures() throws {
        let lines = try fixture("text-native-over.txt")
        #expect(lines.count == 160)
        for line in lines {
            let values = line.split(separator: " ")
            #expect(values.count == 5)
            guard values.count == 5 else { continue }
            let format: SurfaceFormat = values[0] == "565" ? .r565 : .x555
            let source = try hex(values[1]), destination = try hex(values[2]), expected = try hex(values[4])
            let alpha = try #require(UInt8(values[3]))
            var image = PixelBuffer(width: 1,height: 1,fill: RasterPixelFormat.expand(destination,format: format))
            let pattern = PixelBuffer(width: 1,height: 1,pixels: [source],hasAlpha: true)
            try image.text(string(format: .a8,data: [alpha],width: 1,height: 1),
                           foreground: .pattern(pattern,origin: .init(x: 0,y: 0)),background: nil,
                           backgroundArea: image.bounds,box: image.bounds,clip: .none,mode: .opPut,format: format)
            #expect(image[0,0] == RasterPixelFormat.expand(expected,format: format),"Oracle: \(line)")
        }
    }

    @Test func nativeBackgroundIsQuantizedBeforeForegroundOver() throws {
        let lines = try fixture("text-native-sequence.txt")
        #expect(lines.count == 240)
        for line in lines {
            let values = line.split(separator: " ")
            #expect(values.count == 5)
            guard values.count == 5 else { continue }
            let format: SurfaceFormat = values[0] == "565" ? .r565 : .x555
            let background = try hex(values[1]), foreground = try hex(values[2]), expected = try hex(values[4])
            let alpha = try #require(UInt8(values[3]))
            let back = PixelBuffer(width: 1,height: 1,pixels: [background],hasAlpha: true)
            let fore = PixelBuffer(width: 1,height: 1,pixels: [foreground],hasAlpha: true)
            var image = PixelBuffer(width: 1,height: 1)
            try image.text(string(format: .a8,data: [alpha],width: 1,height: 1),
                           foreground: .pattern(fore,origin: .init(x: 0,y: 0)),
                           background: .pattern(back,origin: .init(x: 0,y: 0)),
                           backgroundArea: image.bounds,box: image.bounds,clip: .none,mode: .opPut,format: format)
            #expect(image[0,0] == RasterPixelFormat.expand(expected,format: format),"Sequence: \(line)")
        }
    }

    @Test func nativeSolidWordsUseDistinct555And565Layouts() throws {
        for (format,color,expected): (SurfaceFormat,UInt32,UInt32) in [
            (.x555,0x1084,0xFF212121),(.r565,0x2084,0xFF211021)
        ] {
            var image = PixelBuffer(width: 1,height: 1)
            try image.text(string(format: .a8,data: [255],width: 1,height: 1),foreground: .color(color),
                           background: nil,backgroundArea: image.bounds,box: image.bounds,clip: .none,
                           mode: .opPut,format: format)
            #expect(image[0,0] == expected)
        }
    }

    @Test func incompleteA8RowsRejectBeforeBackgroundPainting() {
        var image = PixelBuffer(width: 2,height: 2)
        #expect(throws: TextRasterError.invalidGlyphs) {
            try image.text(string(format: .a8,data: [255,0,128],width: 2,height: 2),foreground: .color(.max),
                           background: .color(.max),backgroundArea: image.bounds,box: image.bounds,clip: .none,mode: .opPut)
        }
        #expect(image.pixels.allSatisfy { $0 == 0xFF000000 })
    }

    private func string(format: GlyphFormat,data: [UInt8],width: Int,height: Int,topDown: Bool = false) -> RasterString {
        .init(format: format,topDown: topDown,glyphs: [
            .init(renderPosition: .init(x: 0,y: 0),origin: .init(x: 0,y: 0),width: width,height: height,data: data)
        ])
    }
    private func fixture(_ name: String) throws -> [Substring] {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/" + name)
        return try String(contentsOf: path,encoding: .utf8).split(separator: "\n")
    }
    private func hex(_ value: Substring) throws -> UInt32 { try #require(UInt32(value,radix: 16)) }
}
