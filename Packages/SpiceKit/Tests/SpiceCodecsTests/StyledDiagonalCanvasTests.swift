import Testing
@testable import SpiceCodecs
import SpiceWire

struct StyledDiagonalCanvasTests {
    @Test func allOctantsAndReversedEndpointsMatchPinnedPixels() throws {
        // Fixed outputs from the pinned, unchanged software reference; translated
        // by (12,12) to retain negative-coordinate coverage in a native surface.
        let fixtures: [([Int], [Int])] = [
            ([0,0,8,8], [396,429,495,528,594,627]),
            ([8,8,0,0], [429,462,528,561,627]),
            ([0,0,8,-8], [179,210,272,303,365,396]),
            ([8,-8,0,0], [179,241,272,334,365]),
            ([0,0,8,4], [396,397,429,464,465,497,531]),
            ([8,4,0,0], [396,397,431,463,464,499,531]),
            ([0,0,8,-4], [275,305,336,337,365,396,397]),
            ([8,-4,0,0], [275,307,335,336,367,396,397]),
            ([0,0,4,8], [396,428,429,526,558,559,624]),
            ([4,8,0,0], [396,428,493,494,526,623,624]),
            ([0,0,4,-8], [176,238,239,270,364,365,396]),
            ([4,-8,0,0], [175,176,270,301,302,364,396]),
            ([0,0,9,3], [396,397,432,465,500]),
            ([9,3,0,0], [396,397,432,465,500]),
            ([0,0,9,-3], [308,337,368,396,397]),
            ([9,-3,0,0], [308,337,368,396,397]),
            ([0,0,-8,8], [427,489,520,582,613]),
            ([-8,8,0,0], [427,458,520,551,613,644]),
            ([0,0,-8,-8], [165,198,264,297,363]),
            ([-8,-8,0,0], [132,165,231,264,330,363]),
            ([0,0,-8,4], [395,427,455,456,487,516,517]),
            ([-8,4,0,0], [395,425,456,457,485,516,517]),
            ([0,0,-8,-4], [260,261,295,327,328,363,395]),
            ([-8,-4,0,0], [260,261,293,328,329,361,395]),
            ([0,0,-4,8], [427,428,522,553,554,616,648]),
            ([-4,8,0,0], [428,490,491,522,616,617,648]),
            ([0,0,-4,-8], [136,168,233,234,266,363,364]),
            ([-4,-8,0,0], [136,168,169,266,298,299,364]),
            ([0,0,-9,3], [395,424,455,483,484]),
            ([-9,3,0,0], [395,424,455,483,484]),
            ([0,0,-9,-3], [291,292,327,360,395]),
            ([-9,-3,0,0], [291,292,327,360,395]),
        ]
        for (coordinates, expected) in fixtures {
            var image = PixelBuffer(width: 32, height: 32)
            try draw(&image, [(coordinates[0]+12, coordinates[1]+12),
                              (coordinates[2]+12, coordinates[3]+12)])
            #expect(lit(image) == expected.sorted(), "Endpoints: \(coordinates)")
        }
    }

    @Test func clipUnionAndNativeBrushReuseExistingRasterRules() throws {
        var image = PixelBuffer(width: 10, height: 10)
        try draw(&image, [(0,0),(8,8)], clip: .rects([
            .init(x: 3, y: 3, width: 5, height: 5), .init(x: 3, y: 3, width: 5, height: 5)
        ]), mode: .opXor)
        #expect(lit(image) == [33,44,66,77])
        image = PixelBuffer(width: 10, height: 10)
        try image.strokeStyled(path: path([(0,0),(8,8)]), attributes: .init(flags: 8, style: [32,32]),
                               brush: .color(0xF800), box: image.bounds, clip: .none, mode: .opPut, format: .r565)
        #expect(image[0,0] == 0xFFFF_0000)
        #expect(image[2,2] == 0xFF00_0000)
    }

    @Test func extremeOffscreenDistanceDoesNotWalkInvisibleDashes() throws {
        var image = PixelBuffer(width: 4, height: 4)
        let figure = StrokeSegment(flags: [.begin,.end], points: [
            .init(x: .min, y: .min), .init(x: .max, y: .max)
        ])
        try image.strokeStyled(path: .init(segments: [figure]), attributes: .init(flags: 8, style: [4080]),
                               brush: .color(.max), box: image.bounds, clip: .none, mode: .opPut)
        #expect(lit(image) == [0,5,10,15])
    }

    @Test func exhaustedClipWorkLeavesDiagonalPixelsUnchanged() {
        var image = PixelBuffer(width: 64, height: 64)
        #expect(throws: StrokeError.workLimit) {
            try draw(&image, [(0,0),(63,63)], clip: .rects(Array(repeating: image.bounds, count: 65_536)))
        }
        #expect(lit(image).isEmpty)
    }

    @Test func mixedFiguresResetPhaseAndApplyXorSeparately() throws {
        var image = PixelBuffer(width: 10, height: 10)
        let diagonal = path([(0,0),(8,8)]).segments[0]
        let axis = path([(0,0),(8,0)]).segments[0]
        try image.strokeStyled(path: .init(segments: [diagonal,axis]), attributes: .init(flags: 8, style: [32,32]),
                               brush: .color(.max), box: image.bounds, clip: .none, mode: .opXor)
        #expect(lit(image) == [1,4,5,11,33,44,66,77])
    }

    private func path(_ points: [(Int,Int)]) -> StrokePath {
        .init(segments: [.init(flags: [.begin,.end], points: points.map {
            .init(x: Int32($0.0 * 16), y: Int32($0.1 * 16))
        })])
    }
    private func draw(_ image: inout PixelBuffer, _ points: [(Int,Int)],
                      clip: Clip = .none, mode: Ropd = .opPut) throws {
        try image.strokeStyled(path: path(points), attributes: .init(flags: 8, style: [32,32]),
                               brush: .color(.max), box: image.bounds, clip: clip, mode: mode)
    }
    private func lit(_ image: PixelBuffer) -> [Int] { image.pixels.indices.filter { image.pixels[$0] == .max } }
}
