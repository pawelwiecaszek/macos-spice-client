import Testing
@testable import SpiceCodecs
import SpiceWire

struct CubicCanvasTests {
    @Test func archMatchesPixelsFromThePinnedReferencePolyline() throws {
        var target = PixelBuffer(width: 5, height: 4)
        try target.strokeSolid(path: arch(), brush: .color(.max), box: target.bounds, clip: .none, mode: .opPut)
        #expect(lit(target) == [0, 6, 8, 11, 13, 17])
        #expect(target[4, 0] == 0xFF00_0000, "the final endpoint is excluded")
    }

    @Test func closingCubicFigureDoesNotXorItsFirstEndpointTwice() throws {
        var target = PixelBuffer(width: 5, height: 4)
        try target.strokeSolid(path: arch(close: true), brush: .color(0x00FF_FFFF), box: target.bounds, clip: .none, mode: .opXor)
        #expect(lit(target) == [0, 1, 2, 3, 4, 6, 8, 11, 13, 17])
    }

    @Test func curveStartsAtThePreviousRoundedEndpoint() throws {
        let path = StrokePath(segments: [.init(flags: [.begin, .end, .bezier], points: [
            p(9, 7), p(32, 48), p(64, 48), p(80, 0)
        ])])
        var target = PixelBuffer(width: 6, height: 4)
        try target.strokeSolid(path: path, brush: .color(.max), box: target.bounds, clip: .none, mode: .opPut)
        #expect(lit(target) == [1, 8, 10, 15])
    }

    @Test func clippingACurveKeepsTheUnclippedRasterPhase() throws {
        var reference = PixelBuffer(width: 5, height: 4)
        try reference.strokeSolid(path: arch(), brush: .color(.max), box: reference.bounds, clip: .none, mode: .opPut)
        for x in 0..<5 {
            var target = PixelBuffer(width: 5, height: 4)
            try target.strokeSolid(path: arch(), brush: .color(.max), box: target.bounds,
                                   clip: .rects([Rect(x: x, y: 0, width: 1, height: 4)]), mode: .opPut)
            for y in 0..<4 { #expect(target[x, y] == reference[x, y]) }
            #expect(lit(target).allSatisfy { $0 % 5 == x })
        }
    }

    @Test func straightCubicUsesTheSamePixelsAsAStraightSegment() throws {
        let curve = StrokePath(segments: [.init(flags: [.begin, .end, .bezier], points: [
            p(0, 0), p(16, 16), p(32, 32), p(48, 48)
        ])])
        let line = StrokePath(segments: [.init(flags: [.begin, .end], points: [p(0, 0), p(48, 48)])])
        var actual = PixelBuffer(width: 4, height: 4), expected = actual
        try actual.strokeSolid(path: curve, brush: .color(.max), box: actual.bounds, clip: .none, mode: .opPut)
        try expected.strokeSolid(path: line, brush: .color(.max), box: expected.bounds, clip: .none, mode: .opPut)
        #expect(actual == expected)
    }

    @Test func degenerateCurveTerminatesWithoutChangingPixels() throws {
        let zero = p(0, 0)
        let path = StrokePath(segments: [.init(flags: [.begin, .end, .bezier], points: [zero, zero, zero, zero])])
        var target = PixelBuffer(width: 1, height: 1)
        #expect(try target.strokeSolid(path: path, brush: .color(.max), box: target.bounds, clip: .none, mode: .opPut).isEmpty)
        #expect(target[0, 0] == 0xFF00_0000)
    }

    @Test func oneSharedSubdivisionBudgetRejectsBeforeAnEarlierLinePaints() {
        let first = StrokeSegment(flags: [.begin, .end], points: [p(0, 0), p(16, 0)])
        let curve = StrokeSegment(flags: [.begin, .end, .bezier], points: [p(0, 0), p(0, 1024), p(1024, 1024), p(1024, 0)])
        let path = StrokePath(segments: [first] + Array(repeating: curve, count: 4095))
        var target = PixelBuffer(width: 65, height: 65)
        #expect(throws: StrokeError.workLimit) {
            try target.strokeSolid(path: path, brush: .color(.max), box: target.bounds, clip: .none, mode: .opPut)
        }
        #expect(target.pixels.allSatisfy { $0 == 0xFF00_0000 })
    }

    @Test func continuationAndMultipleCubicsUseEachRoundedPreviousEndpoint() throws {
        let mixed = StrokePath(segments: [
            .init(flags: .begin, points: [p(0, 0), p(9, 7)]),
            .init(flags: [.bezier, .end], points: [p(32, 48), p(64, 48), p(80, 0)])
        ])
        let doubled = StrokePath(segments: [.init(flags: [.begin, .bezier, .end], points: [
            p(0, 0), p(0, 0), p(8, 0), p(9, 7), p(32, 48), p(64, 48), p(80, 0)
        ])])
        for path in [mixed, doubled] {
            var target = PixelBuffer(width: 6, height: 4)
            try target.strokeSolid(path: path, brush: .color(.max), box: target.bounds, clip: .none, mode: .opPut)
            #expect(lit(target) == [0, 1, 8, 10, 15])
        }
    }

    @Test func pruningDistantCurvePiecesDoesNotChangeTheVisiblePixels() throws {
        let path = StrokePath(segments: [.init(flags: [.begin, .end, .bezier], points: [
            p(0, 0), p(0, 1024), p(1024, 1024), p(1024, 0)
        ])])
        var full = PixelBuffer(width: 65, height: 65), clipped = full
        let region = Rect(x: 30, y: 44, width: 5, height: 7)
        try full.strokeSolid(path: path, brush: .color(.max), box: full.bounds, clip: .none, mode: .opPut)
        try clipped.strokeSolid(path: path, brush: .color(.max), box: clipped.bounds, clip: .rects([region]), mode: .opPut)
        #expect(!lit(clipped).isEmpty)
        for y in 0..<65 {
            for x in 0..<65 {
                let inside = x >= Int(region.left) && x < Int(region.right) && y >= Int(region.top) && y < Int(region.bottom)
                #expect(clipped[x, y] == (inside ? full[x, y] : 0xFF00_0000))
            }
        }
    }

    @Test func cubicUsesNative16BitBrushWords() throws {
        var target = PixelBuffer(width: 5, height: 4)
        try target.strokeSolid(path: arch(), brush: .color(0xF800), box: target.bounds, clip: .none, mode: .opPut, format: .r565)
        #expect(target.pixels.indices.filter { target.pixels[$0] == 0xFFFF_0000 } == [0, 6, 8, 11, 13, 17])
    }

    private func arch(close: Bool = false) -> StrokePath {
        let flags: StrokeFlags = close ? [.begin, .end, .bezier, .close] : [.begin, .end, .bezier]
        return StrokePath(segments: [.init(flags: flags, points: [p(0, 0), p(0, 64), p(64, 64), p(64, 0)])])
    }
    private func p(_ x: Int32, _ y: Int32) -> StrokePoint { .init(x: x, y: y) }
    private func lit(_ image: PixelBuffer) -> [Int] { image.pixels.indices.filter { image.pixels[$0] == .max } }
}
