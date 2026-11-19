import Testing
@testable import AudioHost

#if canImport(AVFoundation)
struct AudioRenderTimelineTests {
    @Test func prebufferSilenceDoesNotAdvancePacketTime() throws {
        var ring = try makeRing()
        ring.append(pcm(frames: 80), channels: 2, time: 100)
        #expect(ring.beginRender(frames: 80, channels: 2, expectedGeneration: 7) == 0)
        ring.finishRender(playedFrames: 0, requestedFrames: 80, channels: 2, hostTime: 1)
        #expect(ring.renderedPosition == nil)
        #expect(ring.timeline?.queuedFrames == 80 && ring.count == 160)
        ring.append(pcm(frames: 400), channels: 2, time: 110)
        let available = ring.beginRender(frames: 80, channels: 2, expectedGeneration: 7)
        let played = try #require(available)
        ring.finishRender(playedFrames: played, requestedFrames: 80, channels: 2, hostTime: 42)
        let position = try #require(ring.renderedPosition)
        #expect(position.startTime == 100 && position.endTime == 110)
        #expect(position.hostTime == 42 && position.playbackEpoch == 7)
        #expect(position.frameCount == 80 && position.sampleRate == 8000)
        #expect(ring.timeline?.queuedFrames == 400 && ring.count == 800)
    }

    @Test func pcmOverwriteAndHighWaterTrimKeepTheSameTimestampTail() throws {
        var ring = try makeRing(channels: 1)
        ring.append(Array(repeating: 123, count: 32_768), channels: 1, time: 1000)
        #expect(ring.count == 480 && ring.timeline?.queuedFrames == 480)
        #expect(ring.beginRender(frames: 480, channels: 1, expectedGeneration: 7) == 480)
        ring.finishRender(playedFrames: 480, requestedFrames: 480, channels: 1, hostTime: nil)
        let position = try #require(ring.renderedPosition)
        #expect(position.startTime == 5036 && position.endTime == 5096)
        #expect(position.hostTime == nil)
        #expect(ring.timeline?.queuedFrames == 0 && ring.count == 0)
    }

    @Test func underrunAndUnknownRegionsNeverPublishAPresentationEstimate() throws {
        var ring = try makeRing()
        ring.append(pcm(frames: 480), channels: 2, time: 100)
        _ = ring.beginRender(frames: 400, channels: 2, expectedGeneration: 7)
        ring.finishRender(playedFrames: 400, requestedFrames: 400, channels: 2, hostTime: 1)
        #expect(ring.renderedPosition != nil)
        ring.finishRender(playedFrames: 80, requestedFrames: 100, channels: 2, hostTime: 2)
        #expect(ring.renderedPosition == nil && !ring.playing)
        #expect(ring.timeline?.queuedFrames == 0 && ring.count == 0)
        ring.append(pcm(frames: 480), channels: 2, time: nil)
        _ = ring.beginRender(frames: 80, channels: 2, expectedGeneration: 7)
        ring.finishRender(playedFrames: 80, requestedFrames: 80, channels: 2, hostTime: 3)
        #expect(ring.renderedPosition == nil)
    }

    @Test func discontinuitiesInvalidateOldQueueTimingAndRecoverAtTheNewPacket() throws {
        var ring = try makeRing()
        ring.append(pcm(frames: 480), channels: 2, time: 100)
        _ = ring.beginRender(frames: 80, channels: 2, expectedGeneration: 7)
        ring.finishRender(playedFrames: 80, requestedFrames: 80, channels: 2, hostTime: 1)
        let oldEpoch = try #require(ring.renderedPosition).timelineEpoch
        ring.append(pcm(frames: 80), channels: 2, time: 900)
        #expect(ring.renderedPosition == nil)
        ring.finishRender(playedFrames: 400, requestedFrames: 400, channels: 2, hostTime: 2)
        #expect(ring.renderedPosition == nil)
        ring.finishRender(playedFrames: 80, requestedFrames: 80, channels: 2, hostTime: 3)
        let position = try #require(ring.renderedPosition)
        #expect(position.startTime == 900 && position.endTime == 910)
        #expect(position.timelineEpoch != oldEpoch)
    }

    @Test func staleRenderGenerationCannotConsumeANewPlaybackQueue() throws {
        var ring = try makeRing()
        ring.append(pcm(frames: 480), channels: 2, time: 42)
        #expect(ring.beginRender(frames: 80, channels: 2, expectedGeneration: 6) == nil)
        #expect(ring.count == 960 && ring.timeline?.queuedFrames == 480 && !ring.playing)
        #expect(ring.beginRender(frames: 80, channels: 2, expectedGeneration: 7) == 80)
        ring.finishRender(playedFrames: 80, requestedFrames: 80, channels: 2, hostTime: 1)
        #expect(ring.renderedPosition?.startTime == 42)
    }

    @Test func partialChannelFramesAndOversizedPcmRejectWithoutChangingTheQueue() throws {
        var ring = try makeRing()
        ring.append([1,2,3], channels: 2, time: 100)
        #expect(ring.count == 0 && ring.timeline?.queuedFrames == 0)
        ring.append(Array(repeating: 1, count: 192_000 * 8 + 2), channels: 2, time: 100)
        #expect(ring.count == 0 && ring.timeline?.queuedFrames == 0)
        ring.append(pcm(frames: 480), channels: 2, time: 100)
        #expect(ring.count == 960 && ring.timeline?.queuedFrames == 480)
    }

    @Test func raisingMinimumClearsTheRenderPositionUntilPlaybackResumes() throws {
        var ring = try makeRing()
        ring.append(pcm(frames: 480), channels: 2, time: 100)
        _ = ring.beginRender(frames: 80, channels: 2, expectedGeneration: 7)
        ring.finishRender(playedFrames: 80, requestedFrames: 80, channels: 2, hostTime: 1)
        #expect(ring.renderedPosition != nil)
        let policy = try #require(AudioBufferingPolicy(channels: 2, sampleRate: 8000, minimumLatencyMilliseconds: 300))
        ring.apply(policy)
        #expect(!ring.playing && ring.renderedPosition == nil)
        #expect(ring.count == 800 && ring.timeline?.queuedFrames == 400)
    }

    @Test func deliveryLossFlushesPcmAndTimingButRetainsOutputPolicy() throws {
        var ring = try makeRing()
        ring.append(pcm(frames: 480), channels: 2, time: 100)
        _ = ring.beginRender(frames: 80, channels: 2, expectedGeneration: 7)
        ring.finishRender(playedFrames: 80, requestedFrames: 80, channels: 2, hostTime: 1)
        let epoch = try #require(ring.renderedPosition).timelineEpoch
        ring.discardQueuedAudio()
        #expect(ring.count == 0 && ring.read == 0 && !ring.playing)
        #expect(ring.timeline?.queuedFrames == 0 && ring.renderedPosition == nil)
        #expect(ring.startThreshold == 960 && ring.maxBuffered == 4000)
        #expect(ring.generation == 7 && ring.startTime == 42)
        ring.append(pcm(frames: 480), channels: 2, time: 900)
        _ = ring.beginRender(frames: 80, channels: 2, expectedGeneration: 7)
        ring.finishRender(playedFrames: 80, requestedFrames: 80, channels: 2, hostTime: 2)
        let recovered = try #require(ring.renderedPosition)
        #expect(recovered.startTime == 900 && recovered.timelineEpoch != epoch)
    }

    private func makeRing(channels: Int = 2) throws -> AudioPlayer.Ring {
        let policy = try #require(AudioBufferingPolicy(channels: channels, sampleRate: 8000))
        return AudioPlayer.Ring(samples: Array(repeating: 0, count: policy.capacitySamples),
                                startThreshold: policy.startThresholdSamples, maxBuffered: policy.maximumBufferedSamples,
                                timeline: PlaybackTimeline(sampleRate: 8000), generation: 7, startTime: 42)
    }
    private func pcm(frames: Int) -> [Int16] { Array(repeating: 123, count: frames * 2) }
}
#endif
