import Testing
@testable import AudioHost

struct PlaybackTimelineTests {
    @Test func partialConsumptionAndTrimmingKeepTheOriginalPacketAnchor() throws {
        var timeline = try timeline()
        #expect(timeline.append(frameCount: 480, time: 1000).accepted)
        let first = try consume(&timeline, frames: 120)
        #expect(first.frameCount == 120 && first.startTime == 1000 && first.endTime == 1002)
        #expect(timeline.trimOldest(frames: 120) == 120)
        let second = try consume(&timeline, frames: 240)
        #expect(second.startTime == 1005 && second.endTime == 1010)
        #expect(second.epoch == first.epoch)
        #expect(timeline.queuedFrames == 0)
        #expect(timeline.consume(frames: 1) == nil)
    }

    @Test func fractionalRatePacketsDoNotAccumulatePerPacketRounding() throws {
        var timeline = try timeline(rate: 44_100)
        for packet in 0..<441 {
            let time = UInt32(1000 + packet * 100 * 1000 / 44_100)
            let result = timeline.append(frameCount: 100, time: time)
            #expect(result.accepted && !result.discontinuity && !result.metadataLimited)
        }
        for packet in 0..<441 {
            let result = try consume(&timeline, frames: 100)
            #expect(result.startTime == UInt32(1000 + packet * 100 * 1000 / 44_100))
            #expect(result.endTime == UInt32(1000 + (packet + 1) * 100 * 1000 / 44_100))
        }
    }

    @Test func timestampWrapIsContinuousAndOneMillisecondQuantizationIsTolerated() throws {
        var timeline = try timeline(rate: 8000)
        #expect(!timeline.append(frameCount: 80, time: .max - 4).discontinuity)
        #expect(!timeline.append(frameCount: 80, time: 6).discontinuity) // Expected 5, tolerated +1.
        let result = try consume(&timeline, frames: 160)
        #expect(result.startTime == UInt32.max - 4)
        #expect(result.endTime == 15)
    }

    @Test func duplicateBackwardAndLargeForwardPacketsInvalidateOlderQueuedTiming() throws {
        for next: UInt32 in [1000,900,2000] {
            var timeline = try timeline()
            _ = timeline.append(frameCount: 480, time: 1000)
            let epoch = timeline.epoch
            #expect(timeline.append(frameCount: 480, time: next).discontinuity)
            #expect(timeline.epoch != epoch)
            let old = try consume(&timeline, frames: 480)
            #expect(old.startTime == nil && old.endTime == nil)
            let current = try consume(&timeline, frames: 480)
            #expect(current.startTime == next && current.endTime == next &+ 10)
        }
    }

    @Test func rangesCrossingUnknownMetadataNeverClaimContinuity() throws {
        var timeline = try timeline()
        _ = timeline.append(frameCount: 480, time: 1000)
        _ = timeline.append(frameCount: 480, time: nil)
        _ = timeline.append(frameCount: 480, time: 1020)
        let mixed = try consume(&timeline, frames: 960)
        #expect(mixed.frameCount == 960 && mixed.startTime == nil && mixed.endTime == nil)
        let fresh = try consume(&timeline, frames: 480)
        #expect(fresh.startTime == 1020 && fresh.endTime == 1030)
    }

    @Test func metadataSaturationPreservesFramesAndRecoversAtAFreshAnchor() throws {
        var timeline = try #require(PlaybackTimeline(sampleRate: 48_000, maxSegments: 2))
        _ = timeline.append(frameCount: 480, time: 1000)
        _ = timeline.append(frameCount: 480, time: nil)
        let limited = timeline.append(frameCount: 480, time: 1020)
        #expect(limited.accepted && limited.metadataLimited)
        #expect(timeline.queuedFrames == 1440)
        _ = timeline.append(frameCount: 480, time: 1030)
        let unknown = try consume(&timeline, frames: 1440)
        #expect(unknown.startTime == nil && unknown.endTime == nil)
        let fresh = try consume(&timeline, frames: 480)
        #expect(fresh.startTime == 1030 && fresh.endTime == 1040)
    }

    @Test func anOversizedPacketAndHighWaterTrimSkipFramesAnalytically() throws {
        var timeline = try timeline(rate: 8000)
        let result = timeline.append(frameCount: 32_768, time: 1000)
        #expect(result.accepted && result.trimmedFrames == 24_768)
        #expect(timeline.queuedFrames == 8000)
        #expect(timeline.trimOldest(frames: 7520) == 7520)
        let tail = try consume(&timeline, frames: 480)
        #expect(tail.startTime == 5036 && tail.endTime == 5096)
    }

    @Test func invalidCountsRejectWithoutChangingQueuedMetadata() throws {
        var timeline = try timeline()
        _ = timeline.append(frameCount: 480, time: 1000)
        let epoch = timeline.epoch
        for count in [Int.min,-1,Int.max] {
            #expect(!timeline.append(frameCount: count, time: 4000).accepted)
            #expect(timeline.queuedFrames == 480 && timeline.epoch == epoch)
        }
        #expect(timeline.trimOldest(frames: -1) == 0)
        #expect(timeline.consume(frames: -1) == nil)
        #expect(timeline.append(frameCount: 0, time: 9000).accepted)
        let result = try consume(&timeline, frames: .max)
        #expect(result.frameCount == 480 && result.startTime == 1000 && result.endTime == 1010)
    }

    @Test func maximumAcceptedCountStaysBoundedAndResetStartsAFreshEpoch() throws {
        var timeline = try timeline(rate: 8000)
        let result = timeline.append(frameCount: Int(Int32.max), time: 10)
        #expect(result.accepted && result.trimmedFrames == Int(Int32.max) - 8000)
        let tail = try consume(&timeline, frames: 8000)
        #expect(tail.startTime == 10 &+ UInt32((Int64(Int32.max) - 8000) * 1000 / 8000))
        #expect(tail.endTime == 10 &+ UInt32(Int64(Int32.max) * 1000 / 8000))
        let epoch = timeline.epoch
        _ = timeline.append(frameCount: 80, time: 2000)
        timeline.reset()
        #expect(timeline.queuedFrames == 0 && timeline.epoch != epoch)
        #expect(timeline.consume(frames: .max) == nil)
        _ = timeline.append(frameCount: 80, time: 42)
        let fresh = try consume(&timeline, frames: 80)
        #expect(fresh.startTime == 42 && fresh.endTime == 52)
    }

    @Test func invalidConfigurationFailsBeforeAllocatingSlots() {
        for rate in [Int.min,0,7999,192001,Int.max] {
            #expect(PlaybackTimeline(sampleRate: rate) == nil)
        }
        for frames in [Int.min,0,48001,Int.max] {
            #expect(PlaybackTimeline(sampleRate: 48_000,maxFrames: frames) == nil)
        }
        for segments in [Int.min,0,2049,Int.max] {
            #expect(PlaybackTimeline(sampleRate: 48_000,maxSegments: segments) == nil)
        }
    }

    @Test func boundedMetadataRingTracksPcmCountsUnderMixedOperations() throws {
        var timeline = try #require(PlaybackTimeline(sampleRate: 8000, maxFrames: 37, maxSegments: 2))
        var expected = 0, generatedFrames = 0
        var seed: UInt32 = 7
        for index in 0..<1000 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            switch seed % 3 {
            case 0:
                let frames = Int(seed % 15) + 1
                let timestamp = index % 2 == 0 ? UInt32(generatedFrames / 8) : nil
                let result = timeline.append(frameCount: frames, time: timestamp)
                #expect(result.accepted)
                #expect(result.trimmedFrames == max(0, expected + frames - 37))
                expected = min(37, expected + frames)
                generatedFrames += frames
            case 1:
                let frames = Int(seed % 50)
                #expect(timeline.trimOldest(frames: frames) == min(frames, expected))
                expected -= min(frames, expected)
            default:
                let frames = Int(seed % 50)
                let result = timeline.consume(frames: frames)
                #expect((result?.frameCount ?? 0) == min(frames, expected))
                expected -= min(frames, expected)
            }
            #expect(timeline.queuedFrames == expected)
        }
    }

    private func consume(_ timeline: inout PlaybackTimeline, frames: Int) throws -> PlaybackTimeline.Consumption {
        let result = timeline.consume(frames: frames)
        return try #require(result)
    }

    private func timeline(rate: Int = 48_000) throws -> PlaybackTimeline {
        try #require(PlaybackTimeline(sampleRate: rate))
    }
}
