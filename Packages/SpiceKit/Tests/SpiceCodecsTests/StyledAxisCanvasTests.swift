import Testing
@testable import SpiceCodecs
import SpiceWire

struct StyledAxisCanvasTests {
    @Test func horizontalReverseAndVerticalPixelsMatchThePinnedOracle() throws {
        let fixtures: [([(Int, Int)], [Int], Bool, [Int])] = [
            ([(0,0),(8,0)], [2,2], false, [0,1,4,5]),
            ([(8,0),(0,0)], [2,2], false, [2,3,6,7]),
            ([(4,0),(0,0)], [2,2], false, [2,3]),
            ([(0,0),(8,0)], [3,1], false, [0,1,2,4,5,6]),
            ([(8,0),(0,0)], [3,1], false, [1,2,3,5,6,7]),
            ([(0,0),(8,0)], [3,1], true, [3,7]),
            ([(0,0),(8,0)], [2,3,1], false, [0,1,5,6,7]),
            ([(0,0),(8,0)], [2,3,1], true, [1,2,3,4,5,7])
        ]
        for (points, style, gap, expected) in fixtures {
            var horizontal = PixelBuffer(width: 10, height: 1)
            try draw(&horizontal, points, style: style, gap: gap)
            #expect(lit(horizontal) == expected)
            var vertical = PixelBuffer(width: 1, height: 10)
            try draw(&vertical, points.map { ($0.1, $0.0) }, style: style, gap: gap)
            #expect(lit(vertical) == expected)
        }
    }

    @Test func cornerPhaseAndOddStartGapMatchThePinnedOracle() throws {
        let points = [(0,0),(3,0),(3,5)]
        for (style, gap, expected): ([Int], Bool, [Int]) in [
            ([2,2], false, [0,1,13,23]),
            ([3,1], false, [0,1,2,13,23,33]),
            ([2,3,1], true, [1,2,3,13,23,43])
        ] {
            var target = PixelBuffer(width: 10, height: 6)
            try draw(&target, points, style: style, gap: gap)
            #expect(lit(target) == expected)
        }
    }

    @Test func geometricMiterAddsTheTurningPixelAndClosesASquare() throws {
        var corner = PixelBuffer(width: 10, height: 5)
        try draw(&corner, [(0,3),(3,3),(3,0)], style: [20,1], mode: .opXor)
        #expect(lit(corner) == [3,13,23,30,31,32,33])
        var square = PixelBuffer(width: 4, height: 4)
        try draw(&square, [(0,0),(3,0),(3,3),(0,3)], style: [20,1], close: true, mode: .opXor)
        #expect(lit(square) == [0,1,2,3,4,7,8,11,12,13,14,15])
    }

    @Test func retracesUnionCoverageWithinAFigureButNotAcrossFigures() throws {
        var target = PixelBuffer(width: 5, height: 1)
        try draw(&target, [(0,0),(4,0),(0,0)], style: [20,1], mode: .opXor)
        #expect(lit(target) == [0,1,2,3])
        target = PixelBuffer(width: 5, height: 1)
        let figure = path([(0,0),(4,0)]).segments[0]
        try target.strokeStyled(path: .init(segments: [figure, figure]), attributes: attributes([20,1]),
                                brush: .color(.max), box: target.bounds, clip: .none, mode: .opXor)
        #expect(lit(target).isEmpty)
    }

    @Test func newFiguresResetDashPhase() throws {
        let first = path([(0,0),(3,0)]).segments[0]
        let second = path([(0,1),(8,1)]).segments[0]
        var target = PixelBuffer(width: 10, height: 2)
        try target.strokeStyled(path: .init(segments: [first, second]), attributes: attributes([2,2]),
                                brush: .color(.max), box: target.bounds, clip: .none, mode: .opPut)
        #expect(lit(target) == [0,1,10,11,14,15])
    }

    @Test func offscreenDistancesAndClipUnionsDoNotResetPhase() throws {
        var target = PixelBuffer(width: 10, height: 1)
        try draw(&target, [(-2,0),(8,0)], style: [2,2])
        #expect(lit(target) == [2,3,6,7])
        target = PixelBuffer(width: 10, height: 1)
        try draw(&target, [(10,0),(-2,0)], style: [2,2])
        #expect(lit(target) == [0,1,4,5,8,9])
        var clipped = PixelBuffer(width: 10, height: 1)
        try draw(&clipped, [(10,0),(-2,0)], style: [2,2], clip: .rects([
            Rect(x: 1, y: 0, width: 6, height: 1), Rect(x: 1, y: 0, width: 6, height: 1)
        ]), mode: .opXor)
        #expect(lit(clipped) == [1,4,5])
    }

    @Test func patternSnapshotsAndNative16BitBrushWordsWorkWithDashes() throws {
        var target = PixelBuffer(width: 3, height: 1, pixels: [0xFF00_0001,0xFF00_0002,0xFF00_0004], hasAlpha: false)
        let snapshot = target
        try target.strokeStyled(path: path([(0,0),(3,0)]), attributes: attributes([20,1]),
                                brush: .pattern(snapshot, origin: .init(x: -1, y: 0)), box: target.bounds, clip: .none, mode: .opPut)
        #expect(target.pixels == [0xFF00_0002,0xFF00_0004,0xFF00_0001])
        target = PixelBuffer(width: 5, height: 1)
        try target.strokeStyled(path: path([(0,0),(4,0)]), attributes: attributes([2,2]),
                                brush: .color(0xF800), box: target.bounds, clip: .none, mode: .opPut, format: .r565)
        #expect(target.pixels == [0xFFFF_0000,0xFFFF_0000,0xFF00_0000,0xFF00_0000,0xFF00_0000])
    }

    @Test func unsupportedCurvesLeaveEarlierSegmentsUnpainted() {
        var target = PixelBuffer(width: 5, height: 5)
        let zero = StrokePoint(x: 0, y: 0)
        #expect(throws: StrokeError.unsupported) {
            try target.strokeStyled(path: .init(segments: [.init(flags: [.begin,.end,.bezier], points: [zero,zero,zero,zero])]),
                                    attributes: attributes([2,2]), brush: .color(.max), box: target.bounds, clip: .none, mode: .opPut)
        }
        #expect(lit(target).isEmpty)
    }

    @Test func workBudgetExhaustionIsDetectedBeforePainting() {
        let figure = path([(0,0),(1,0)]).segments[0]
        var target = PixelBuffer(width: 1, height: 1)
        #expect(throws: StrokeError.workLimit) {
            try target.strokeStyled(path: .init(segments: Array(repeating: figure, count: 129)),
                                    attributes: attributes([2,2]), brush: .color(.max), box: target.bounds,
                                    clip: .rects(Array(repeating: target.bounds, count: 65_536)), mode: .opPut)
        }
        #expect(lit(target).isEmpty)
    }

    @Test func hugeOffscreenSegmentsUseBoundedPhaseQueries() throws {
        var target = PixelBuffer(width: 4, height: 1)
        let figure = StrokeSegment(flags: [.begin,.end], points: [.init(x: .min, y: 0),.init(x: .max, y: 0)])
        try target.strokeStyled(path: .init(segments: [figure]), attributes: attributes([2,2]),
                                brush: .color(.max), box: target.bounds, clip: .none, mode: .opPut)
        #expect(lit(target) == [0,1])
    }

    @Test func oddListWrapUsesTheReferenceEndpointRuleAtAnUpwardJoin() throws {
        var normal = PixelBuffer(width: 10, height: 3)
        try draw(&normal, [(0,2),(6,2),(6,0)], style: [2,3,1], mode: .opXor)
        #expect(lit(normal) == [6,16,20,21,25])
        #expect(normal[6,2] == 0xFF00_0000)
        var gap = PixelBuffer(width: 10, height: 3)
        try draw(&gap, [(0,2),(3,2),(3,0)], style: [2,3,1], gap: true, mode: .opXor)
        #expect(lit(gap) == [3,13,21,22])
        #expect(gap[3,2] == 0xFF00_0000)
    }

    private func attributes(_ lengths: [Int], gap: Bool = false) -> StrokeAttributes {
        .init(flags: gap ? 12 : 8, style: lengths.map { Int32($0 * 16) })
    }
    private func path(_ points: [(Int,Int)], close: Bool = false) -> StrokePath {
        .init(segments: [.init(flags: close ? [.begin,.end,.close] : [.begin,.end],
                              points: points.map { .init(x: Int32($0.0 * 16), y: Int32($0.1 * 16)) })])
    }
    private func draw(_ target: inout PixelBuffer, _ points: [(Int,Int)], style: [Int], gap: Bool = false,
                      close: Bool = false, clip: Clip = .none, mode: Ropd = .opPut) throws {
        try target.strokeStyled(path: path(points, close: close), attributes: attributes(style, gap: gap),
                                brush: .color(.max), box: target.bounds, clip: clip, mode: mode)
    }
    private func lit(_ image: PixelBuffer) -> [Int] { image.pixels.indices.filter { image.pixels[$0] == .max } }
}
