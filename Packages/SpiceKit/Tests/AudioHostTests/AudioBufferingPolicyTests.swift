import Testing
@testable import AudioHost

struct AudioBufferingPolicyTests {
    @Test func defaultPolicyRetainsExistingQueueTargets() throws {
        let policy = try #require(AudioBufferingPolicy(channels: 2, sampleRate: 48_000))
        #expect(policy.minimumBufferMilliseconds == 60)
        #expect(policy.maximumBufferMilliseconds == 250)
        #expect(policy.startThresholdSamples == 5_760)
        #expect(policy.maximumBufferedSamples == 24_000)
        #expect(policy.capacitySamples == 96_000)
    }

    @Test func allSupportedFormatsAndHostileRequestsStayFrameAlignedAndBounded() throws {
        for channels in 1...8 {
            for rate in [8_000,11_025,22_050,44_100,48_000,96_000,192_000] {
                for request: UInt32 in [0,1,60,61,250,500,750,1_000,.max] {
                    let policy = try #require(AudioBufferingPolicy(channels: channels, sampleRate: rate,
                                                                  minimumLatencyMilliseconds: request))
                    #expect((60...750).contains(policy.minimumBufferMilliseconds))
                    #expect(policy.maximumBufferMilliseconds <= 940)
                    #expect(policy.startThresholdSamples % channels == 0)
                    #expect(policy.maximumBufferedSamples % channels == 0)
                    #expect(policy.startThresholdSamples <= policy.maximumBufferedSamples)
                    #expect(policy.maximumBufferedSamples <= policy.capacitySamples)
                    let frames = policy.startThresholdSamples / channels
                    #expect(frames * 1000 >= rate * policy.minimumBufferMilliseconds)
                    #expect((frames - 1) * 1000 < rate * policy.minimumBufferMilliseconds)
                }
            }
        }
    }

    @Test func invalidFormatsRejectBeforeAllocationArithmetic() {
        for channels in [Int.min,-1,0,9,Int.max] {
            #expect(AudioBufferingPolicy(channels: channels, sampleRate: 48_000) == nil)
        }
        for rate in [Int.min,-1,0,7_999,192_001,Int.max] {
            #expect(AudioBufferingPolicy(channels: 2, sampleRate: rate) == nil)
        }
    }

    #if canImport(AVFoundation)
    @Test func raisingMinimumRebuffersOnlyWhenTheNewTargetNeedsMoreAudio() throws {
        let initial = try policy(0), raised = try policy(300)
        var ring = AudioPlayer.Ring(samples: Array(repeating: 0, count: initial.capacitySamples),
                                    count: 9_600, playing: true,
                                    startThreshold: initial.startThresholdSamples, maxBuffered: initial.maximumBufferedSamples)
        ring.apply(raised)
        #expect(!ring.playing)
        #expect(ring.count == 9_600)
        #expect(ring.startThreshold == 28_800)
        #expect(ring.maxBuffered == 47_040)

        ring.count = 40_000
        ring.playing = true
        ring.apply(try policy(350))
        #expect(ring.playing, "A raised target already met by the queue must not interrupt playback")
    }

    @Test func repeatedOrLowerTargetsDoNotInterruptSteadyPlayback() throws {
        let initial = try policy(300)
        var ring = AudioPlayer.Ring(samples: Array(repeating: 0, count: initial.capacitySamples),
                                    count: 3_840, playing: true,
                                    startThreshold: initial.startThresholdSamples, maxBuffered: initial.maximumBufferedSamples)
        ring.apply(initial)
        #expect(ring.playing)
        ring.apply(try policy(0))
        #expect(ring.playing, "Normal draining below the minimum is not an underrun")
        #expect(ring.count == 3_840)
    }

    @Test func loweringHighWaterDropsOldFramesToTheNewStartTarget() throws {
        let initial = try policy(750), reduced = try policy(0)
        var ring = AudioPlayer.Ring(samples: Array(repeating: 0, count: initial.capacitySamples),
                                    read: 2_000, count: 67_200, playing: true,
                                    startThreshold: initial.startThresholdSamples, maxBuffered: initial.maximumBufferedSamples)
        ring.apply(reduced)
        #expect(ring.count == reduced.startThresholdSamples)
        #expect(ring.read == (2_000 + 67_200 - reduced.startThresholdSamples) % initial.capacitySamples)
        #expect(ring.read % reduced.channels == 0)
        #expect(ring.playing)
    }

    @Test func overflowTrimmingWrapsWithoutSplittingAFrame() throws {
        let policy = try #require(AudioBufferingPolicy(channels: 3, sampleRate: 11_025,
                                                      minimumLatencyMilliseconds: 61))
        var ring = AudioPlayer.Ring(samples: Array(repeating: 0, count: policy.capacitySamples),
                                    read: policy.capacitySamples - 3, count: policy.capacitySamples,
                                    startThreshold: policy.startThresholdSamples, maxBuffered: policy.maximumBufferedSamples)
        ring.dropExcess(channels: policy.channels)
        #expect(ring.count == policy.startThresholdSamples)
        #expect(ring.read % policy.channels == 0)
        #expect(ring.read >= 0 && ring.read < ring.samples.count)
    }

    private func policy(_ request: UInt32) throws -> AudioBufferingPolicy {
        try #require(AudioBufferingPolicy(channels: 2, sampleRate: 48_000,
                                         minimumLatencyMilliseconds: request))
    }
    #endif
}
