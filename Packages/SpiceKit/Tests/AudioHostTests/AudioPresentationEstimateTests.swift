import Testing
@testable import AudioHost

struct AudioPresentationEstimateTests {
    @Test func reportedLatencyIsAppliedOnceAndRoundedUpForDelayReporting() throws {
        let estimate = try #require(calculate(start: 1000, delta: 0.25, latency: 0.125))
        #expect(estimate.serverTime == 1125)
        #expect(estimate.outputDelayMilliseconds == 125)
        let fractional = try #require(calculate(start: 1000, delta: 0.125, latency: 0.0625))
        #expect(fractional.serverTime == 1062)
        #expect(fractional.outputDelayMilliseconds == 63)
    }

    @Test func signedOffsetsUseFloorRatherThanTruncationOrUnsignedSubtraction() throws {
        let negative = try #require(calculate(start: 1000, delta: 0.0623779296875, latency: 0.0625))
        #expect(negative.serverTime == 999)
        let positive = try #require(calculate(start: 1000, delta: 0.0626220703125, latency: 0.0625))
        #expect(positive.serverTime == 1000)
        let future = try #require(calculate(start: 1000, delta: -0.0625, latency: 0.125))
        #expect(future.serverTime == 812)
    }

    @Test func zeroAndBothUnsignedWrapDirectionsAreValidServerTimes() throws {
        let zero = try #require(calculate(start: 0, delta: 0.125, latency: 0.125))
        #expect(zero.serverTime == 0)
        let forward = try #require(calculate(start: UInt32.max - 5, delta: 0.125, latency: 0.0625))
        #expect(forward.serverTime == 56)
        let backward = try #require(calculate(start: 0, delta: 0.0625, latency: 0.125))
        #expect(backward.serverTime == UInt32.max - 62)
    }

    @Test func initialPrebufferWaitsForTheContinuousIntervalToReachTheDevice() throws {
        #expect(calculate(start: 1000, delta: 0.01, latency: 0.125, elapsed: 0) == nil)
        #expect(calculate(start: 1000, delta: 0.01, latency: 0.125, elapsed: 0.124) == nil)
        let boundary = try #require(calculate(start: 1000, delta: 0.125, latency: 0.125, elapsed: 0.125))
        #expect(boundary.serverTime == 1000)
    }

    @Test func freshFutureBlocksRemainUsableAfterLongLatencyPlaybackBecameAudible() throws {
        #expect(calculate(start: 1000, delta: -0.0625, latency: 0.75, elapsed: 0.5) == nil)
        let estimate = try #require(calculate(start: 1000, delta: -0.0625, latency: 0.75, elapsed: 2))
        #expect(estimate.serverTime == 187)
        #expect(estimate.outputDelayMilliseconds == 750)
    }

    @Test func renderFreshnessBoundsAreSeparateFromContinuousPlaybackAge() {
        #expect(calculate(start: 1000, delta: 0.25, latency: 0.125) != nil)
        #expect(calculate(start: 1000, delta: -0.1, latency: 0.125) != nil)
        #expect(calculate(start: 1000, delta: 0.250001, latency: 0.125, elapsed: 1000) == nil)
        #expect(calculate(start: 1000, delta: -0.100001, latency: 0.125) == nil)
    }

    @Test func unknownNonfiniteAndUnboundedInputsRejectBeforeIntegerConversion() {
        for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
            #expect(calculate(start: 1000, delta: value, latency: 0.125) == nil)
            #expect(calculate(start: 1000, delta: 0.125, latency: value) == nil)
        }
        for value in [Double.nan, .infinity, -.infinity, -1] {
            #expect(calculate(start: 1000, delta: 0.125, latency: 0.125, elapsed: value) == nil)
        }
        for latency in [0, -0.001, 1.000001] {
            #expect(calculate(start: 1000, delta: 0.125, latency: latency) == nil)
        }
        #expect(calculate(start: 1000, delta: 0.125, latency: 1, elapsed: 1) != nil)
    }

    private func calculate(start: UInt32, delta: Double, latency: Double,
                           elapsed: Double = 2) -> AudioPresentationEstimate? {
        AudioPresentationEstimate.calculate(serverStart: start, hostTimeDeltaSeconds: delta,
                                            outputLatencySeconds: latency,
                                            continuousRenderElapsedSeconds: elapsed)
    }
}
