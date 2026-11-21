import Testing
@testable import SpiceCodecs
import SpiceWire

@Suite("ROP3 canvas")
struct Rop3CanvasTests {
    @Test func allTruthTablesMatchEveryPatternSourceDestinationBitTriple() {
        for code in UInt16(0)...255 {
            for index in 0..<8 {
                let pattern: UInt32 = index & 4 == 0 ? 0 : .max
                let source = PixelBuffer(width: 1, height: 1, fill: index & 2 == 0 ? 0 : .max, hasAlpha: true)
                var target = PixelBuffer(width: 1, height: 1, fill: index & 1 == 0 ? 0 : .max, hasAlpha: true)
                target.rop3(from: source, sourceArea: source.bounds, brush: .color(pattern),
                            box: target.bounds, clip: .none, rop: UInt8(code))
                let expected: UInt32 = code & (1 << index) == 0 ? 0 : .max
                #expect(target[0, 0] == expected)
            }
        }
    }

    @Test func multibitPixelsUseIndependentBitwiseOracleIncludingAlpha() {
        let patterns: [(UInt32, UInt32, UInt32)] = [
            (0x8182_8384, 0x1122_3344, 0x5566_7788),
            (0xFFFF_0000, 0x00FF_00FF, 0xF0F0_0F0F),
            (0, .max, 0x1234_5678)
        ]
        for code in UInt16(0)...255 {
            for (p, s, d) in patterns {
                let source = PixelBuffer(width: 1, height: 1, fill: s, hasAlpha: true)
                var target = PixelBuffer(width: 1, height: 1, fill: d, hasAlpha: true)
                target.rop3(from: source, sourceArea: source.bounds, brush: .color(p),
                            box: target.bounds, clip: .none, rop: UInt8(code))
                #expect(target[0, 0] == oracle(UInt8(code), pattern: p, source: s, destination: d))
            }
        }
    }

    @Test func xRGBForcesOpaqueOutputWhileARGBHighByteParticipates() {
        let source = PixelBuffer(width: 1, height: 1, fill: 0x1245_6789, hasAlpha: true)
        var opaque = PixelBuffer(width: 1, height: 1, fill: 0xFF00_0000)
        opaque.rop3(from: source, sourceArea: source.bounds, brush: .color(0), box: opaque.bounds, clip: .none, rop: 0)
        #expect(opaque[0, 0] == 0xFF00_0000)
        var alpha = PixelBuffer(width: 1, height: 1, fill: 0xFF00_0000, hasAlpha: true)
        alpha.rop3(from: source, sourceArea: source.bounds, brush: .color(0), box: alpha.bounds, clip: .none, rop: 0xCC)
        #expect(alpha[0, 0] == 0x1245_6789)
    }

    @Test func native16BitRasterOperationsQuantizeOperandsBeforeEvaluation() {
        let source = PixelBuffer(width: 1, height: 1, fill: 0xFF00_FF00)
        var x555 = PixelBuffer(width: 1, height: 1, fill: 0xFF00_00FF)
        x555.rop3(from: source, sourceArea: source.bounds, brush: .color(0x7C00),
                  box: x555.bounds, clip: .none, rop: 0x96, format: .x555)
        #expect(x555[0, 0] == 0xFFFF_FFFF)
        let halfGreen = PixelBuffer(width: 1, height: 1, fill: 0xFF00_8000)
        var r565 = PixelBuffer(width: 1, height: 1, fill: 0xFF00_00FF)
        r565.rop3(from: halfGreen, sourceArea: halfGreen.bounds, brush: .color(0xF800),
                  box: r565.bounds, clip: .none, rop: 0x96, format: .r565)
        #expect(r565[0, 0] == 0xFFFF_82FF)
        var patterned = PixelBuffer(width: 1, height: 1)
        let pattern = PixelBuffer(width: 1, height: 1, fill: 0xFF12_3456)
        patterned.rop3(from: source, sourceArea: source.bounds, brush: .pattern(pattern, origin: Point(x: 0, y: 0)),
                       box: patterned.bounds, clip: .none, rop: 0xF0, format: .r565)
        #expect(patterned[0, 0] == 0xFF10_3452)
    }

    @Test func nearestScalingSamplesPixelCentersAtNonIntegralRatios() {
        let source = PixelBuffer(width: 2, height: 1, pixels: [0xFF00_0001, 0xFF00_0002], hasAlpha: false)
        var enlarged = PixelBuffer(width: 3, height: 1)
        enlarged.rop3(from: source, sourceArea: source.bounds, brush: .color(0), box: enlarged.bounds, clip: .none, rop: 0xCC)
        #expect(enlarged.pixels == [0xFF00_0001, 0xFF00_0002, 0xFF00_0002])
        let three = PixelBuffer(width: 3, height: 1, pixels: [0xFF00_0001, 0xFF00_0002, 0xFF00_0003], hasAlpha: false)
        var reduced = PixelBuffer(width: 2, height: 1)
        reduced.rop3(from: three, sourceArea: three.bounds, brush: .color(0), box: reduced.bounds, clip: .none, rop: 0xCC)
        #expect(reduced.pixels == [0xFF00_0001, 0xFF00_0003])
    }

    @Test func repeatedClipWorkIsRejectedBeforeAnyMutation() {
        let source = PixelBuffer(width: 1, height: 1, fill: 0xFFFF_FFFF)
        var target = PixelBuffer(width: 1, height: 1)
        let clip = Clip.rects(Array(repeating: target.bounds, count: 65_536))
        #expect(!target.rop3WorkIsBounded(box: target.bounds, clip: clip))
        #expect(target.rop3(from: source, sourceArea: source.bounds, brush: .color(0), box: target.bounds,
                            clip: clip, rop: 0xCC).isEmpty)
        #expect(target[0, 0] == 0xFF00_0000)
    }

    @Test func patternTilingUsesDestinationCoordinatesAndNegativeOrigin() {
        let source = PixelBuffer(width: 1, height: 1)
        let pattern = PixelBuffer(width: 2, height: 1, pixels: [0xFF11_1111, 0xFF22_2222], hasAlpha: false)
        var target = PixelBuffer(width: 4, height: 2)
        target.rop3(from: source, sourceArea: source.bounds, brush: .pattern(pattern, origin: Point(x: -1, y: -2)),
                    box: target.bounds, clip: .none, rop: 0xF0)
        #expect(target.pixels == [0xFF22_2222, 0xFF11_1111, 0xFF22_2222, 0xFF11_1111,
                                 0xFF22_2222, 0xFF11_1111, 0xFF22_2222, 0xFF11_1111])
    }

    @Test func overlappingClipRectanglesApplyAnInversionOnlyOnce() {
        let source = PixelBuffer(width: 4, height: 1)
        var target = PixelBuffer(width: 4, height: 1, fill: 0xFF12_3456)
        let dirty = target.rop3(from: source, sourceArea: source.bounds, brush: .color(0),
                               box: target.bounds, clip: .rects([target.bounds, Rect(x: 1, y: 0, width: 2, height: 1), target.bounds]), rop: 0x55)
        #expect(target.pixels == Array(repeating: 0xFFED_CBA9, count: 4))
        #expect(dirty == target.bounds)
    }

    @Test func clipsAndMasksPreserveUnpaintedPixelsAndOutOfRangeMaskIsExcluded() {
        let source = PixelBuffer(width: 4, height: 1, pixels: [0xFF00_0001, 0xFF00_0002, 0xFF00_0003, 0xFF00_0004], hasAlpha: false)
        var target = PixelBuffer(width: 4, height: 1)
        let mask = DrawMask(width: 2, height: 1, bits: [true, false], inverted: true, origin: Point(x: -1, y: 0))
        let dirty = target.rop3(from: source, sourceArea: source.bounds, brush: .color(0), box: target.bounds,
                               clip: .rects([Rect(x: 1, y: 0, width: 3, height: 1)]), rop: 0xCC, mask: mask)
        #expect(target.pixels == [0xFF00_0000, 0xFF00_0000, 0xFF00_0003, 0xFF00_0000])
        #expect(dirty == Rect(x: 2, y: 0, width: 1, height: 1))
        let blocked = DrawMask(width: 4, height: 1, bits: [false, false, false, false], inverted: false, origin: Point(x: 0, y: 0))
        #expect(target.rop3(from: source, sourceArea: source.bounds, brush: .color(0), box: target.bounds,
                           clip: .none, rop: 0xFF, mask: blocked).isEmpty)
    }

    @Test func nearestScalingKeepsOriginalBoxCoordinatesAfterClipping() {
        let source = PixelBuffer(width: 2, height: 1, pixels: [0xFF11_1111, 0xFF22_2222], hasAlpha: false)
        var target = PixelBuffer(width: 3, height: 1)
        let dirty = target.rop3(from: source, sourceArea: source.bounds, brush: .color(0),
                               box: Rect(x: -1, y: 0, width: 4, height: 1), clip: .none, rop: 0xCC)
        #expect(target.pixels == [0xFF11_1111, 0xFF22_2222, 0xFF22_2222])
        #expect(dirty == target.bounds)
    }

    @Test func interpolationClampsToSourceAreaAndUsesPixelCenters() {
        let source = PixelBuffer(width: 4, height: 1, pixels: [0xFFFF_0000, 0xFF00_0000, 0xFF00_00FF, 0xFF00_FF00], hasAlpha: false)
        var target = PixelBuffer(width: 4, height: 1)
        target.rop3(from: source, sourceArea: Rect(x: 1, y: 0, width: 2, height: 1), brush: .color(0),
                    box: target.bounds, clip: .none, rop: 0xCC, scaleMode: .interpolate)
        #expect(target.pixels == [0xFF00_0000, 0xFF00_003F, 0xFF00_00BF, 0xFF00_00FF])
    }

    @Test func extremeBoxesAndInvalidSourceAreasDoNotOverflowOrModifyOutsideBounds() {
        let source = PixelBuffer(width: 1, height: 1, fill: 0xFF12_3456)
        var target = PixelBuffer(width: 2, height: 1)
        target.rop3(from: source, sourceArea: source.bounds, brush: .color(0),
                    box: Rect(left: .min, top: .min, right: .max, bottom: .max), clip: .none, rop: 0xCC)
        #expect(target.pixels == [0xFF12_3456, 0xFF12_3456])
        let before = target
        for area in [Rect(left: .min, top: 0, right: .max, bottom: 1),
                     Rect(x: 0, y: 0, width: 2, height: 1), Rect(x: 0, y: 0, width: 0, height: 1)] {
            #expect(target.rop3(from: source, sourceArea: area, brush: .color(0), box: target.bounds, clip: .none, rop: 0).isEmpty)
            #expect(target == before)
        }
    }

    @Test func emptyPatternsMalformedMasksAndUnsupportedFormatsAreNoOps() {
        let source = PixelBuffer(width: 1, height: 1)
        var target = PixelBuffer(width: 1, height: 1, fill: 0xFF12_3456)
        let before = target
        #expect(target.rop3(from: source, sourceArea: source.bounds,
                           brush: .pattern(PixelBuffer(width: 0, height: 0), origin: Point(x: 0, y: 0)),
                           box: target.bounds, clip: .none, rop: 0).isEmpty)
        let malformed = DrawMask(width: .max, height: 2, bits: [], inverted: false, origin: Point(x: 0, y: 0))
        #expect(target.rop3(from: source, sourceArea: source.bounds, brush: .color(0), box: target.bounds,
                           clip: .none, rop: 0, mask: malformed).isEmpty)
        for format: SurfaceFormat in [.invalid, .a1, .a8] {
            #expect(target.rop3(from: source, sourceArea: source.bounds, brush: .color(0), box: target.bounds,
                               clip: .none, rop: 0, format: format).isEmpty)
        }
        #expect(target == before)
    }

    private func oracle(_ code: UInt8, pattern: UInt32, source: UInt32, destination: UInt32) -> UInt32 {
        var result: UInt32 = 0
        for bit in 0..<32 {
            let index = Int(((pattern >> bit) & 1) * 4 + ((source >> bit) & 1) * 2 + ((destination >> bit) & 1))
            if code & (1 << index) != 0 { result |= UInt32(1) << bit }
        }
        return result
    }
}
