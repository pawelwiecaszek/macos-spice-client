import Foundation
import Testing
@testable import SpiceCodecs
import SpiceWire

struct StyledJoinCanvasTests {
    @Test func turnsAcrossOctantsMatchCopyAndXorReferencePixels() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/styled-join-oracle.txt")
        let lines = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 256)
        for line in lines {
            let halves = line.split(separator: ":", omittingEmptySubsequences: false)
            let header = halves[0].split(separator: ",").compactMap { Int($0) }
            let expected = halves[1].split(separator: " ").map { coordinate -> Int in
                let values = coordinate.trimmingCharacters(in: CharacterSet(charactersIn: "()*"))
                    .split(separator: ",").compactMap { Int($0) }
                return (values[1]+16)*32 + values[0]+16
            }.sorted()
            let positions = [(-header[0],-header[1]),(0,0),(header[2],header[3])]
            let points = positions.map { StrokePoint(x: Int32(($0.0+16)*16), y: Int32(($0.1+16)*16)) }
            var image = PixelBuffer(width: 32, height: 32)
            try image.strokeStyled(path: .init(segments: [.init(flags: [.begin,.end], points: points)]),
                                   attributes: .init(flags: 8, style: [4080,16]), brush: .color(.max),
                                   box: image.bounds, clip: .none, mode: header[4] == 3 ? .opPut : .opXor)
            #expect(image.pixels.indices.filter { image.pixels[$0] == .max } == expected,
                    "Reference case \(halves[0])")
        }
    }

    @Test func miterCutoffClosureAndRetracesMatchPinnedPixels() throws {
        let fixtures: [([Int], [Int], Bool, Bool, [Int])] = [
            ([-10, -1, 0, 0, -10, 1], [255], false, false, [486, 487, 488, 489, 490, 491, 523, 524, 525, 526, 527, 528, 529, 530, 531, 532, 533, 550, 551, 552, 553, 554, 555]),
            ([-10, -1, 0, 0, -10, 1], [2, 2], false, false, [486, 487, 488, 491, 523, 525, 526, 527, 550, 551, 554, 555]),
            ([-10, -1, 0, 0, -10, 1], [2, 3, 1], true, false, [488, 489, 490, 491, 523, 524, 525, 526, 527, 528, 529, 530, 531, 532, 533, 550, 551, 552, 554, 555]),
            ([-10, -1, 0, 0, -10, 1], [255], false, true, [486, 487, 488, 489, 490, 491, 523, 524, 525, 526, 527, 528, 529, 530, 531, 532, 533, 550, 551, 552, 553, 554, 555]),
            ([-10, -1, 0, 0, -10, 1], [2, 2], false, true, [486, 487, 488, 491, 523, 525, 526, 527, 550, 551, 554, 555]),
            ([-10, -1, 0, 0, -10, 1], [2, 3, 1], true, true, [488, 489, 490, 491, 523, 524, 525, 526, 527, 528, 529, 530, 531, 532, 533, 550, 551, 552, 554, 555]),
            ([-11, -1, 0, 0, -11, 1], [255], false, false, [485, 486, 487, 488, 489, 490, 523, 524, 525, 526, 527, 528, 549, 550, 551, 552, 553, 554]),
            ([-11, -1, 0, 0, -11, 1], [2, 2], false, false, [485, 486, 487, 490, 523, 525, 526, 527, 551, 552]),
            ([-11, -1, 0, 0, -11, 1], [2, 3, 1], true, false, [487, 488, 489, 490, 523, 524, 525, 526, 527, 549, 550, 551, 552, 553]),
            ([-11, -1, 0, 0, -11, 1], [255], false, true, [485, 486, 487, 488, 489, 490, 523, 524, 525, 526, 527, 528, 549, 550, 551, 552, 553, 554]),
            ([-11, -1, 0, 0, -11, 1], [2, 2], false, true, [485, 486, 487, 490, 523, 525, 526, 527, 551, 552]),
            ([-11, -1, 0, 0, -11, 1], [2, 3, 1], true, true, [487, 488, 489, 490, 523, 524, 525, 526, 527, 549, 550, 551, 552, 553]),
            ([10, 1, 0, 0, 10, -1], [255], false, false, [501, 502, 503, 504, 505, 528, 529, 530, 531, 532, 533, 565, 566, 567, 568, 569]),
            ([10, 1, 0, 0, 10, -1], [2, 2], false, false, [501, 502, 505, 529, 530, 531, 533, 565, 568, 569]),
            ([10, 1, 0, 0, 10, -1], [2, 3, 1], true, false, [501, 502, 504, 505, 528, 529, 530, 531, 532, 533, 565, 566, 567, 568]),
            ([10, 1, 0, 0, 10, -1], [255], false, true, [501, 502, 503, 504, 505, 523, 524, 525, 526, 527, 528, 529, 530, 531, 532, 533, 565, 566, 567, 568, 569]),
            ([10, 1, 0, 0, 10, -1], [2, 2], false, true, [501, 502, 505, 529, 530, 531, 533, 565, 568, 569]),
            ([10, 1, 0, 0, 10, -1], [2, 3, 1], true, true, [501, 502, 504, 505, 523, 524, 525, 526, 527, 528, 529, 530, 531, 532, 533, 565, 566, 567, 568]),
            ([11, 1, 0, 0, 11, -1], [255], false, false, [502, 503, 504, 505, 506, 528, 529, 530, 531, 532, 533, 566, 567, 568, 569, 570]),
            ([11, 1, 0, 0, 11, -1], [2, 2], false, false, [504, 505, 528, 529, 530, 531, 533, 566, 569, 570]),
            ([11, 1, 0, 0, 11, -1], [2, 3, 1], true, false, [503, 504, 505, 506, 528, 529, 530, 531, 532, 533, 566, 567, 568, 569]),
            ([11, 1, 0, 0, 11, -1], [255], false, true, [502, 503, 504, 505, 506, 528, 529, 530, 531, 532, 533, 566, 567, 568, 569, 570]),
            ([11, 1, 0, 0, 11, -1], [2, 2], false, true, [504, 505, 528, 529, 530, 531, 533, 566, 569, 570]),
            ([11, 1, 0, 0, 11, -1], [2, 3, 1], true, true, [503, 504, 505, 506, 528, 529, 530, 531, 532, 533, 566, 567, 568, 569]),
            ([0, 0, 4, 4, 8, 0, 0, 0], [255], false, false, [528, 529, 530, 531, 532, 533, 534, 535, 536, 561, 567, 594, 598, 627, 629, 660]),
            ([0, 0, 4, 4, 8, 0, 0, 0], [2, 2], false, false, [528, 530, 531, 534, 535, 561, 598, 627]),
            ([0, 0, 4, 4, 8, 0, 0, 0], [2, 3, 1], true, false, [528, 530, 531, 532, 533, 534, 561, 567, 594, 598, 627, 629]),
            ([0, 0, 4, 4, 8, 0, 0, 0], [255], false, true, [528, 529, 530, 531, 532, 533, 534, 535, 536, 561, 567, 594, 598, 627, 629, 660]),
            ([0, 0, 4, 4, 8, 0, 0, 0], [2, 2], false, true, [528, 530, 531, 534, 535, 561, 598, 627]),
            ([0, 0, 4, 4, 8, 0, 0, 0], [2, 3, 1], true, true, [528, 530, 531, 532, 533, 534, 561, 567, 594, 598, 627, 629]),
            ([0, 0, 4, 4, 0, 0], [255], false, false, [528, 561, 594, 627]),
            ([0, 0, 4, 4, 0, 0], [2, 2], false, false, [528, 561, 594, 627]),
            ([0, 0, 4, 4, 0, 0], [2, 3, 1], true, false, [528, 561, 594, 627]),
            ([0, 0, 4, 4, 0, 0], [255], false, true, [528, 561, 594, 627]),
            ([0, 0, 4, 4, 0, 0], [2, 2], false, true, [528, 561, 594, 627]),
            ([0, 0, 4, 4, 0, 0], [2, 3, 1], true, true, [528, 561, 594, 627]),
            ([0, 0, 4, 4, 8, 4], [255], false, false, [528, 561, 594, 627, 660, 661, 662, 663]),
            ([0, 0, 4, 4, 8, 4], [2, 2], false, false, [528, 561, 627, 662, 663]),
            ([0, 0, 4, 4, 8, 4], [2, 3, 1], true, false, [561, 594, 627, 661, 662, 663]),
            ([0, 0, 4, 4, 8, 4], [255], false, true, [528, 561, 594, 627, 660, 661, 662, 663]),
            ([0, 0, 4, 4, 8, 4], [2, 2], false, true, [528, 561, 627, 662, 663]),
            ([0, 0, 4, 4, 8, 4], [2, 3, 1], true, true, [561, 594, 627, 661, 662, 663]),
            ([0, 0, 1, 1, 2, 2, 3, 3], [255], false, false, [528, 561, 594]),
            ([0, 0, 1, 1, 2, 2, 3, 3], [2, 2], false, false, [528, 594]),
            ([0, 0, 1, 1, 2, 2, 3, 3], [2, 3, 1], true, false, [561, 594]),
            ([0, 0, 1, 1, 2, 2, 3, 3], [255], false, true, [528, 561, 594]),
            ([0, 0, 1, 1, 2, 2, 3, 3], [2, 2], false, true, [528, 594]),
            ([0, 0, 1, 1, 2, 2, 3, 3], [2, 3, 1], true, true, [561, 594]),
            ([0, 0, 4, 0, 8, 4, 8, 0, 0, 0], [255], false, false, [528, 529, 530, 531, 532, 533, 534, 535, 536, 565, 568, 598, 600, 631, 632, 664]),
            ([0, 0, 4, 0, 8, 4, 8, 0, 0, 0], [2, 2], false, false, [528, 529, 532, 533, 536, 565, 568, 631]),
            ([0, 0, 4, 0, 8, 4, 8, 0, 0, 0], [2, 3, 1], true, false, [528, 529, 530, 531, 532, 533, 534, 535, 536, 565, 600, 631, 632, 664]),
            ([0, 0, 4, 0, 8, 4, 8, 0, 0, 0], [255], false, true, [528, 529, 530, 531, 532, 533, 534, 535, 536, 565, 568, 598, 600, 631, 632, 664]),
            ([0, 0, 4, 0, 8, 4, 8, 0, 0, 0], [2, 2], false, true, [528, 529, 532, 533, 536, 565, 568, 631]),
            ([0, 0, 4, 0, 8, 4, 8, 0, 0, 0], [2, 3, 1], true, true, [528, 529, 530, 531, 532, 533, 534, 535, 536, 565, 600, 631, 632, 664]),
        ]
        for (coordinates, style, gap, xor, expected) in fixtures {
            let points = stride(from: 0, to: coordinates.count, by: 2).map {
                StrokePoint(x: Int32((coordinates[$0]+16)*16), y: Int32((coordinates[$0+1]+16)*16))
            }
            var image = PixelBuffer(width: 32, height: 32)
            try image.strokeStyled(path: .init(segments: [.init(flags: [.begin,.end], points: points)]),
                                   attributes: .init(flags: gap ? 12 : 8, style: style.map { Int32($0*16) }),
                                   brush: .color(.max), box: image.bounds, clip: .none, mode: xor ? .opXor : .opPut)
            #expect(image.pixels.indices.filter { image.pixels[$0] == .max } == expected.sorted(),
                    "Path \(coordinates), style \(style), gap \(gap), XOR \(xor)")
        }
    }

    @Test func joinWorkBudgetRejectsEarlierFiguresAtomically() {
        let first = StrokeSegment(flags: [.begin,.end], points: [.init(x: 0,y: 0),.init(x: 16,y: 0)])
        let corner = StrokeSegment(flags: [.begin,.end], points: [
            .init(x: 0,y: 0),.init(x: 64,y: 64),.init(x: 0,y: 128)
        ])
        var image = PixelBuffer(width: 16, height: 16)
        #expect(throws: StrokeError.workLimit) {
            try image.strokeStyled(path: .init(segments: [first,corner]), attributes: .init(flags: 8, style: [4080]),
                                   brush: .color(.max), box: image.bounds,
                                   clip: .rects(Array(repeating: image.bounds, count: 65_536)), mode: .opXor)
        }
        #expect(image.pixels.allSatisfy { $0 == 0xFF00_0000 })
    }

    @Test func joinedDiagonalPhaseAndGeometryMatchPinnedXorFixtures() throws {
        let fixtures: [([Int], [Int], Bool, [Int])] = [
            ([0, 0, 4, 4, 8, 4], [2, 2], false, [264, 297, 363, 398, 399]),
            ([0, 0, 4, 4, 8, 4], [20, 1], false, [264, 297, 330, 363, 396, 397, 398, 399]),
            ([0, 0, 4, 4, 8, 4], [2, 3, 1], true, [297, 330, 363, 397, 398, 399]),
            ([8, 4, 4, 4, 0, 0], [2, 2], false, [264, 297, 363, 398, 399]),
            ([8, 4, 4, 4, 0, 0], [20, 1], false, [264, 297, 330, 363, 396, 397, 398, 399]),
            ([8, 4, 4, 4, 0, 0], [2, 3, 1], true, [264, 297, 363, 396, 397, 398]),
            ([0, 4, 4, 0, 8, 4], [2, 2], false, [299, 334, 361, 392]),
            ([0, 4, 4, 0, 8, 4], [20, 1], false, [268, 299, 301, 330, 334, 361, 367, 392]),
            ([0, 4, 4, 0, 8, 4], [2, 3, 1], true, [299, 301, 330, 334, 361, 367]),
            ([0, 0, 4, 4, 0, 8], [2, 2], false, [264, 297, 363, 458]),
            ([0, 0, 4, 4, 0, 8], [20, 1], false, [264, 297, 330, 363, 396, 427, 458, 489, 520]),
            ([0, 0, 4, 4, 0, 8], [2, 3, 1], true, [297, 330, 363, 427, 458, 489, 520]),
            ([0, 0, 4, 4, 0, 0], [2, 2], false, [264, 297, 330, 363]),
            ([0, 0, 4, 4, 0, 0], [20, 1], false, [264, 297, 330, 363]),
            ([0, 0, 4, 4, 0, 0], [2, 3, 1], true, [264, 297, 330, 363]),
            ([0, 0, 8, 3, 0, 1], [2, 2], false, [264, 265, 296, 297, 300, 332, 333, 367, 368]),
            ([0, 0, 8, 3, 0, 1], [20, 1], false, [264, 265, 296, 297, 298, 299, 300, 330, 331, 332, 333, 334, 366, 367, 368]),
            ([0, 0, 8, 3, 0, 1], [2, 3, 1], true, [296, 297, 298, 299, 300, 330, 331, 332, 333, 334, 366, 367]),
            ([0, 0, 6, 1, 0, 0], [2, 2], false, [264, 265, 266, 299, 300, 301]),
            ([0, 0, 6, 1, 0, 0], [20, 1], false, [264, 265, 266, 267, 299, 300, 301]),
            ([0, 0, 6, 1, 0, 0], [2, 3, 1], true, [264, 266, 267, 299, 300, 301]),
            ([0, 0, 1, 1, 2, 2, 3, 3], [2, 2], false, [264, 330]),
            ([0, 0, 1, 1, 2, 2, 3, 3], [20, 1], false, [264, 297, 330]),
            ([0, 0, 1, 1, 2, 2, 3, 3], [2, 3, 1], true, [297, 330]),
        ]
        for (coordinates, style, gap, expected) in fixtures {
            var image = PixelBuffer(width: 32, height: 32)
            let points = stride(from: 0, to: coordinates.count, by: 2).map {
                StrokePoint(x: Int32((coordinates[$0]+8)*16), y: Int32((coordinates[$0+1]+8)*16))
            }
            try image.strokeStyled(path: .init(segments: [.init(flags: [.begin,.end], points: points)]),
                                   attributes: .init(flags: gap ? 12 : 8, style: style.map { Int32($0*16) }),
                                   brush: .color(.max), box: image.bounds, clip: .none, mode: .opXor)
            #expect(image.pixels.indices.filter { image.pixels[$0] == .max } == expected.sorted(),
                    "Path \(coordinates), style \(style), gap \(gap)")
        }
    }
}
