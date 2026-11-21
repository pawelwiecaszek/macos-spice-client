import Testing
@testable import SpiceCodecs
import SpiceWire

struct StrokeDashPatternTests {
    @Test func evenStylesRepeatTheirForegroundAndGapIntervals() throws {
        let equal = try pattern([2, 2])
        #expect(equal.period == 4)
        #expect(samples(equal, count: 8) == [true, true, false, false, true, true, false, false])
        let unequal = try pattern([3, 1])
        #expect(samples(unequal, count: 8) == [true, true, true, false, true, true, true, false])
    }

    @Test func startWithGapUsesTheReferenceRotationAndOffset() throws {
        let dash = try pattern([3, 1], startsWithGap: true)
        #expect(samples(dash, count: 8) == [false, false, false, true, false, false, false, true])
        #expect(samples(try pattern([2, 2], startsWithGap: true), count: 8) ==
                [false, false, true, true, false, false, true, true])
    }

    @Test func oddListsResetIndexParityAtTheCycleBoundary() throws {
        let dash = try pattern([2, 1, 3])
        #expect(dash.period == 6)
        #expect(samples(dash, count: 12) == [true, true, false, true, true, true,
                                            true, true, false, true, true, true])
        let gap = try pattern([2, 1, 3], startsWithGap: true)
        #expect(samples(gap, count: 12) == [false, false, false, true, true, true,
                                           false, false, false, true, true, true])
    }

    @Test func aSingleReferenceEntryRemainsForegroundOnWrap() throws {
        for startsWithGap in [false, true] {
            let dash = try pattern([2], startsWithGap: startsWithGap)
            #expect(samples(dash, count: 6).allSatisfy { $0 })
            #expect(dash.isForeground(at: .max))
        }
    }

    @Test func fixedPointLengthsRoundExactHalvesDown() throws {
        let dash = try StrokeDashPattern(attributes: .init(flags: 8, style: [24, 25]))
        #expect(dash.period == 3) // 1.5 -> 1, 1.5625 -> 2.
        #expect(samples(dash, count: 6) == [true, false, false, true, false, false])
        let boundary = try StrokeDashPattern(attributes: .init(flags: 8, style: [4088, 9]))
        #expect(boundary.period == 256) // 255.5 -> 255, 0.5625 -> 1.
        #expect(boundary.isForeground(at: 254))
        #expect(!boundary.isForeground(at: 255))
        #expect(boundary.isForeground(at: 256))
    }

    @Test func zeroOrWrappingRoundedLengthsAreUnsupported() {
        for raw: Int32 in [1, 8, 4089, 4096, .max] {
            #expect(throws: StrokeError.unsupported) {
                _ = try StrokeDashPattern(attributes: .init(flags: 8, style: [raw]))
            }
        }
        for raw: Int32 in [0, -1, .min] {
            #expect(throws: StrokeError.invalidPath) {
                _ = try StrokeDashPattern(attributes: .init(flags: 8, style: [raw]))
            }
        }
    }

    @Test func malformedFlagsAndCountsAreRejected() {
        for attributes in [StrokeAttributes(), .init(flags: 4, style: [16]),
                           .init(flags: 9, style: [16]), .init(flags: 8),
                           .init(flags: 8, style: Array(repeating: 16, count: 256))] {
            #expect(throws: StrokeError.invalidPath) { _ = try StrokeDashPattern(attributes: attributes) }
        }
        #expect(throws: Never.self) {
            let maximum = try StrokeDashPattern(attributes: .init(flags: 8, style: Array(repeating: 4080, count: 255)))
            #expect(maximum.period == 65_025)
        }
    }

    @Test func extremeQueriesReduceBeforeAddingTheInitialOffset() throws {
        let normal = try pattern([3, 1])
        #expect(!normal.isForeground(at: -1))
        #expect(normal.isForeground(at: -2))
        #expect(normal.isForeground(at: .min))
        #expect(!normal.isForeground(at: .max))
        let gap = try pattern([3, 1], startsWithGap: true)
        #expect(!gap.isForeground(at: .min))
        #expect(gap.isForeground(at: .max))
    }

    private func pattern(_ lengths: [Int32], startsWithGap: Bool = false) throws -> StrokeDashPattern {
        try StrokeDashPattern(attributes: .init(flags: startsWithGap ? 12 : 8, style: lengths.map { $0 * 16 }))
    }

    private func samples(_ pattern: StrokeDashPattern, count: Int) -> [Bool] {
        (0..<count).map { pattern.isForeground(at: Int64($0)) }
    }
    @Test func oddWrapEndpointStateDiffersFromTheLastForegroundPixel() throws {
        let dash = try StrokeDashPattern(attributes: .init(flags: 8, style: [32,48,16]))
        #expect(dash.isForeground(at: 5))
        #expect(!dash.foregroundBeforeEndpoint(at: 6))
        #expect(dash.isForeground(at: 6))
    }

}
