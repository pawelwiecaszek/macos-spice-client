import Testing
@testable import SpiceCodecs
import SpiceWire

struct StyledCubicCanvasTests {
    @Test func styledCurvePixelsMatchPinnedReference() throws {
        let inputs: [[StrokePoint]] = [
            [p(0,0),p(40,51),p(34,8),p(64,0)],
            [p(0,0),p(0,64),p(64,64),p(64,0)],
            [p(9,7),p(32,48),p(64,48),p(80,0)],
            [p(0,0),p(64,0),p(0,64),p(0,0)],
            [p(0,0),p(0,64),p(64,64),p(64,0)],
            [p(0,0),p(0,64),p(64,64),p(64,0)],
            [p(0,0),p(0,128),p(96,128),p(96,0)]
        ]
        let fixtures: [(Int,Int,Bool,[Int])] = [
            (0, 0, false, [0, 3]),
            (0, 0, true, [0, 3]),
            (0, 1, false, [3, 17, 18, 19]),
            (0, 1, true, [3, 17, 18, 19]),
            (0, 2, false, [0, 3, 17, 18, 19]),
            (0, 2, true, [0, 3, 17, 18, 19]),
            (1, 0, false, [0, 16, 17, 20, 50]),
            (1, 0, true, [0, 16, 17, 20, 50]),
            (1, 1, false, [17, 19, 20, 33, 35, 50]),
            (1, 1, true, [17, 19, 20, 33, 35, 50]),
            (1, 2, false, [0, 16, 17, 19, 20, 33, 35, 50]),
            (1, 2, true, [0, 16, 17, 19, 20, 33, 35, 50]),
            (2, 0, false, [1, 18, 20]),
            (2, 0, true, [1, 18, 20]),
            (2, 1, false, [18, 20, 35]),
            (2, 1, true, [18, 20, 35]),
            (2, 2, false, [1, 18, 20, 35]),
            (2, 2, true, [1, 18, 20, 35]),
            (3, 0, false, [0, 1, 17, 33, 49]),
            (3, 0, true, [0, 1, 17, 33, 49]),
            (3, 1, false, [0, 17, 33, 49]),
            (3, 1, true, [0, 17, 33, 49]),
            (3, 2, false, [0, 1, 16, 17, 18, 19, 33, 49]),
            (3, 2, true, [-17, 0, 1, 16, 17, 18, 19, 33, 49]),
            (4, 0, false, [0, 16, 17, 20, 22, 23, 39, 50, 58, 59]),
            (4, 0, true, [0, 16, 17, 20, 22, 23, 39, 50, 58, 59]),
            (4, 1, false, [4, 5, 17, 19, 20, 21, 23, 33, 35, 39, 40, 41, 50, 57, 58, 59]),
            (4, 1, true, [4, 5, 17, 19, 20, 21, 23, 33, 35, 39, 40, 41, 50, 57, 58, 59]),
            (4, 2, false, [0, 4, 5, 16, 17, 19, 20, 21, 22, 23, 33, 35, 39, 40, 41, 50, 57, 58, 59, 75]),
            (4, 2, true, [0, 4, 5, 16, 17, 19, 20, 21, 22, 23, 33, 35, 39, 40, 41, 50, 57, 58, 59, 75]),
            (5, 0, false, [0, 1, 16, 17, 20, 50]),
            (5, 0, true, [0, 1, 16, 17, 20, 50]),
            (5, 1, false, [0, 2, 3, 4, 17, 19, 20, 33, 35, 50]),
            (5, 1, true, [0, 2, 3, 4, 17, 19, 20, 33, 35, 50]),
            (5, 2, false, [0, 1, 2, 3, 4, 16, 17, 19, 20, 33, 35, 50]),
            (5, 2, true, [0, 1, 2, 3, 4, 16, 17, 19, 20, 33, 35, 50]),
            (6, 0, false, [0, 6, 16, 23, 32, 37, 38, 58, 59, 65, 84, 99]),
            (6, 0, true, [0, 6, 16, 23, 32, 37, 38, 58, 59, 65, 84, 99]),
            (6, 1, false, [6, 22, 23, 32, 33, 38, 41, 49, 53, 58, 59, 65, 69, 84, 99]),
            (6, 1, true, [6, 22, 23, 32, 33, 38, 41, 49, 53, 58, 59, 65, 69, 84, 99]),
            (6, 2, false, [0, 6, 16, 22, 23, 24, 32, 33, 37, 38, 41, 49, 53, 58, 59, 65, 69, 82, 84, 99]),
            (6, 2, true, [0, 6, 16, 22, 23, 24, 32, 33, 37, 38, 41, 49, 53, 58, 59, 65, 69, 82, 84, 99]),
        ]
        for (index, style, xor, expected) in fixtures {
            var flags: StrokeFlags = [.begin,.bezier]
            if index != 4 && index != 6 { flags.insert(.end) }
            if index == 5 { flags.insert(.close) }
            var segments = [StrokeSegment(flags: flags, points: inputs[index])]
            if index == 4 || index == 6 { segments.append(.init(flags: .end, points: [p(192,64)])) }
            let attributes = StrokeAttributes(flags: style == 1 ? 12 : 8,
                                             style: style == 0 ? [32,32] : style == 1 ? [32,48,16] : [4080])
            var image = PixelBuffer(width: 16, height: 16)
            try image.strokeStyled(path: .init(segments: segments), attributes: attributes, brush: .color(.max),
                                   box: image.bounds, clip: .none, mode: xor ? .opXor : .opPut)
            #expect(image.pixels.indices.filter { image.pixels[$0] == .max } == expected.filter { $0 >= 0 && $0 < 256 }.sorted(),
                    "Curve \(index), style \(style), XOR \(xor)")
            if index == 6 {
                var clipped = PixelBuffer(width: 16, height: 16)
                try clipped.strokeStyled(path: .init(segments: segments), attributes: attributes, brush: .color(.max),
                                         box: clipped.bounds, clip: .rects([.init(x: 8,y: 0,width: 8,height: 16)]),
                                         mode: xor ? .opXor : .opPut)
                #expect(clipped.pixels.indices.filter { clipped.pixels[$0] == .max } == expected.filter { $0 % 16 >= 8 }.sorted())
            }
        }
    }

    @Test func clippingPreservesFullCurveDashPhase() throws {
        let curve = path([p(0,0),p(0,1024),p(1024,1024),p(1024,0)])
        var full = PixelBuffer(width: 65, height: 65), clipped = full
        try draw(&full, curve)
        let region = Rect(x: 25, y: 42, width: 15, height: 10)
        try draw(&clipped, curve, clip: .rects([region,region]))
        #expect(clipped.pixels.contains(.max))
        for y in 0..<65 {
            for x in 0..<65 {
                let inside = x >= 25 && x < 40 && y >= 42 && y < 52
                #expect(clipped[x,y] == (inside ? full[x,y] : 0xFF00_0000))
            }
        }
    }

    @Test func fullSubdivisionBudgetRejectsBeforeEarlierFiguresPaint() {
        let line = StrokeSegment(flags: [.begin,.end], points: [p(0,0),p(16,0)])
        let curve = path([p(-2048,-2048),p(-2048,-1024),p(-1024,-1024),p(-1024,-2048)]).segments[0]
        var image = PixelBuffer(width: 4, height: 4)
        #expect(throws: StrokeError.workLimit) {
            try draw(&image, .init(segments: [line] + Array(repeating: curve, count: 4095)))
        }
        #expect(image.pixels.allSatisfy { $0 == 0xFF00_0000 })
    }

    @Test func zeroChordAndBacktrackingTerminateWithinBudget() throws {
        for points in [[p(0,0),p(0,0),p(0,0),p(0,0)],
                       [p(0,0),p(64,0),p(0,64),p(0,0)],
                       [p(0,0),p(128,0),p(-128,0),p(16,0)]] {
            var image = PixelBuffer(width: 10, height: 10)
            try draw(&image, path(points))
        }
    }

    @Test func extremeRoundedEndpointDoesNotOverflowNormalization() throws {
        var image = PixelBuffer(width: 2, height: 2)
        try draw(&image, path([p(.max,.max),p(.max,.max),p(.max,.max),p(.max,.max)]))
        #expect(image.pixels.allSatisfy { $0 == 0xFF00_0000 })
    }

    @Test func native16BitCurveUsesPackedBrushWords() throws {
        var image = PixelBuffer(width: 5, height: 4)
        try image.strokeStyled(path: path([p(0,0),p(0,64),p(64,64),p(64,0)]),
                               attributes: .init(flags: 8, style: [32,32]), brush: .color(0xF800),
                               box: image.bounds, clip: .none, mode: .opPut, format: .r565)
        #expect(image.pixels.contains(0xFFFF_0000))
        #expect(image.pixels.allSatisfy { $0 == 0xFFFF_0000 || $0 == 0xFF00_0000 })
    }

    private func path(_ points: [StrokePoint]) -> StrokePath {
        .init(segments: [.init(flags: [.begin,.bezier,.end], points: points)])
    }
    private func p(_ x: Int32, _ y: Int32) -> StrokePoint { .init(x: x,y: y) }
    private func draw(_ image: inout PixelBuffer, _ path: StrokePath, clip: Clip = .none) throws {
        try image.strokeStyled(path: path, attributes: .init(flags: 8, style: [32,32]), brush: .color(.max),
                               box: image.bounds, clip: clip, mode: .opXor)
    }
}
