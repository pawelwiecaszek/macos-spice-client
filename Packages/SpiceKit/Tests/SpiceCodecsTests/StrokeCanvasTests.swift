import Testing
@testable import SpiceCodecs
import SpiceWire

struct StrokeCanvasTests {
    @Test func horizontalVerticalAndDiagonalExcludeTheirFinalEndpoints() throws {
        for points in [[(0, 0), (4, 0)], [(0, 0), (0, 4)], [(0, 0), (4, 4)]] {
            var target = PixelBuffer(width: 5, height: 5)
            try target.strokeSolid(path: path(points), brush: .color(0x00FF_FFFF), box: target.bounds, clip: .none, mode: .opPut)
            #expect(target.pixels.filter { $0 == 0xFFFF_FFFF }.count == 4)
            #expect(target[points[1].0, points[1].1] == 0xFF00_0000)
        }
    }

    @Test func directionalHalfPixelTiesAndReverseSegmentsHaveGoldenPixels() throws {
        var forward = PixelBuffer(width: 5, height: 3)
        try forward.strokeSolid(path: path([(0, 0), (4, 2)]), brush: .color(.max), box: forward.bounds, clip: .none, mode: .opPut)
        #expect(lit(forward) == [0, 6, 7, 13])
        var reverse = PixelBuffer(width: 5, height: 3)
        try reverse.strokeSolid(path: path([(4, 2), (0, 0)]), brush: .color(.max), box: reverse.bounds, clip: .none, mode: .opPut)
        #expect(lit(reverse) == [6, 7, 13, 14])
    }

    @Test func closedXorFigureDrawsEachSharedVertexOnce() throws {
        var target = PixelBuffer(width: 4, height: 4)
        try target.strokeSolid(path: path([(0, 0), (3, 0), (3, 3), (0, 3)], close: true), brush: .color(0x00FF_FFFF),
                               box: target.bounds, clip: .none, mode: .opXor)
        #expect(target.pixels.filter { $0 == 0xFFFF_FFFF }.count == 12)
        #expect(target[0, 0] == 0xFFFF_FFFF && target[3, 0] == 0xFFFF_FFFF)
        #expect(target[1, 1] == 0xFF00_0000)
    }

    @Test func clipUnionDoesNotApplyXorTwiceAndRetainsRasterPhase() throws {
        var target = PixelBuffer(width: 5, height: 3)
        let clip = Clip.rects([Rect(x: 1, y: 0, width: 3, height: 3), Rect(x: 1, y: 0, width: 3, height: 3)])
        try target.strokeSolid(path: path([(0, 0), (4, 2)]), brush: .color(0x00FF_FFFF), box: target.bounds, clip: clip, mode: .opXor)
        #expect(lit(target) == [6, 7, 13])
    }

    @Test func hugeOffscreenSegmentsSkipDirectlyToVisiblePixels() throws {
        var target = PixelBuffer(width: 4, height: 1)
        let segment = StrokeSegment(flags: [.begin, .end], points: [.init(x: .min, y: 0), .init(x: .max, y: 0)])
        try target.strokeSolid(path: .init(segments: [segment]), brush: .color(.max), box: target.bounds, clip: .none, mode: .opPut)
        #expect(target.pixels == Array(repeating: .max, count: 4))
    }

    @Test func patternAlignmentAndNative16BitColorArePreserved() throws {
        var target = PixelBuffer(width: 4, height: 1)
        let pattern = PixelBuffer(width: 2, height: 1, pixels: [0xFF00_FF00, 0xFFFF_0000], hasAlpha: false)
        try target.strokeSolid(path: path([(0, 0), (4, 0)]), brush: .pattern(pattern, origin: .init(x: -1, y: 0)),
                               box: target.bounds, clip: .none, mode: .opPut, format: .r565)
        #expect(target.pixels == [0xFFFF_0000, 0xFF00_FF00, 0xFFFF_0000, 0xFF00_FF00])
        try target.strokeSolid(path: path([(0, 0), (4, 0)]), brush: .color(0x7C00), box: target.bounds, clip: .none, mode: .opPut, format: .x555)
        #expect(target.pixels == Array(repeating: 0xFFFF_0000, count: 4))
    }

    @Test func brushInversionUsesBrushFlagAndARGBOperatesOnTheNativeWord() throws {
        var target = PixelBuffer(width: 2, height: 1, fill: 0x1122_3344, hasAlpha: true)
        try target.strokeSolid(path: path([(0, 0), (2, 0)]), brush: .color(0x1234_5678), box: target.bounds, clip: .none,
                               mode: [.opPut, .inversSource])
        #expect(target.pixels == [0x1234_5678, 0x1234_5678])
        try target.strokeSolid(path: path([(0, 0), (2, 0)]), brush: .color(0x1234_5678), box: target.bounds, clip: .none,
                               mode: [.opPut, .inversBrush])
        #expect(target.pixels == [0xEDCB_A987, 0xEDCB_A987])
    }

    @Test func excessiveWorkAndUnsupportedCurveLeaveAllPixelsUnchanged() throws {
        var target = PixelBuffer(width: 1, height: 1)
        let lines = Array(repeating: StrokeSegment(flags: [.begin, .end], points: [.init(x: 0, y: 0), .init(x: 16, y: 0)]), count: 129)
        #expect(throws: StrokeError.workLimit) {
            try target.strokeSolid(path: .init(segments: lines), brush: .color(.max), box: target.bounds,
                                   clip: .rects(Array(repeating: target.bounds, count: 65_536)), mode: .opPut)
        }
        #expect(target[0, 0] == 0xFF00_0000)
        let p = StrokePoint(x: 0, y: 0)
        #expect(throws: StrokeError.unsupported) {
            try target.strokeSolid(path: .init(segments: [.init(flags: [.begin, .end, .bezier], points: [p, p, p, p])]),
                                   brush: .color(.max), box: target.bounds, clip: .none, mode: .opPut)
        }
        #expect(target[0, 0] == 0xFF00_0000)
    }

    @Test func directLineSamplingMatchesAnIncrementalOracleInEveryOctant() {
        for x in -5...5 {
            for y in -5...5 {
                let start = Point(x: 0, y: 0), end = Point(x: Int32(x), y: Int32(y))
                let line = CosmeticLine(from: start, to: end)
                let dx = abs(x), dy = abs(y), sx = x < 0 ? -1 : 1, sy = y < 0 ? -1 : 1
                let xMajor = dx > dy, major = max(dx, dy), minor = min(dx, dy)
                let bias = (xMajor ? sx : sy) < 0 ? 1 : 0
                var error = -major - bias, px = 0, py = 0
                for index in 0..<major {
                    let actual = line.point(at: index)
                    #expect(actual.x == px && actual.y == py)
                    error += 2 * minor
                    if error >= 0 {
                        if xMajor { py += sy } else { px += sx }
                        error -= 2 * major
                    }
                    if xMajor { px += sx } else { py += sy }
                }
            }
        }
    }

    @Test func aliasedPatternUsesThePreStrokePixels() throws {
        var target = PixelBuffer(width: 3, height: 1, pixels: [0xFF00_0001, 0xFF00_0002, 0xFF00_0004], hasAlpha: false)
        let pattern = target
        try target.strokeSolid(path: path([(1, 0), (3, 0)]), brush: .pattern(pattern, origin: .init(x: 1, y: 0)),
                               box: target.bounds, clip: .none, mode: .opPut)
        #expect(target.pixels == [0xFF00_0001, 0xFF00_0001, 0xFF00_0002])
    }

    @Test func inversionOnlyDescriptorsRetainTheReferenceDefaultCopy() throws {
        for mode: Ropd in [.inversBrush, .inversSource, .inversDest, .inversResult] {
            var target = PixelBuffer(width: 2, height: 1, hasAlpha: true)
            try target.strokeSolid(path: path([(0, 0), (2, 0)]), brush: .color(0x1234_5678),
                                   box: target.bounds, clip: .none, mode: mode)
            #expect(target.pixels == [0x1234_5678, 0x1234_5678])
        }
    }

    private func path(_ points: [(Int, Int)], close: Bool = false) -> StrokePath {
        StrokePath(segments: [.init(flags: close ? [.begin, .end, .close] : [.begin, .end],
                                  points: points.map { StrokePoint(x: Int32($0.0 * 16), y: Int32($0.1 * 16)) })])
    }
    private func lit(_ buffer: PixelBuffer) -> [Int] { buffer.pixels.indices.filter { buffer.pixels[$0] == .max } }
}
