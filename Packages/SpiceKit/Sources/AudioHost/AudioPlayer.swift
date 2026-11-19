#if canImport(AVFoundation)
import AVFoundation
import Synchronization

public enum AudioPlayerError: Error, Sendable {
    case invalidFormat
}

/// Source-render position, not proof of device presentation. Host time, when
/// valid, describes the first frame of this render block; endTime is exclusive.
public struct AudioRenderPosition: Sendable, Equatable {
    public let startTime: UInt32
    public let endTime: UInt32
    public let hostTime: UInt64?
    public let frameCount: Int
    public let sampleRate: Int
    public let playbackEpoch: UInt64
    public let timelineEpoch: UInt64
}

/// Plays the guest's audio: interleaved S16 PCM goes into a jitter buffer that an
/// `AVAudioSourceNode` drains on the audio thread.
///
/// Playback starts once the bounded minimum is buffered (60 ms by default), pauses
/// on underrun, and drops old audio at its high-water mark (250 ms by default).
public final class AudioPlayer: @unchecked Sendable {
    // Engine objects are only touched from the owning (main) actor; the ring buffer is
    // shared with the render thread under `ring`.
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let ring = RingBox()
    private var renderGeneration: UInt64 = 0
    public private(set) var channels = 2
    public private(set) var sampleRate = 48_000

    /// Reference wrapper so the render block can share the (non-copyable) mutex.
    final class RingBox: Sendable {
        let state = Mutex(Ring())
        func withLock<R: Sendable>(_ body: (inout Ring) -> R) -> R { state.withLock { body(&$0) } }
    }

    struct Ring: Sendable {
        var samples: [Float] = []  // interleaved
        var read = 0
        var count = 0
        var playing = false
        var startThreshold = 0
        var maxBuffered = 0
        var underruns = 0
        var timeline: PlaybackTimeline?
        var renderedPosition: AudioRenderPosition?
        var generation: UInt64 = 0
        var startTime: UInt32?

        mutating func apply(_ policy: AudioBufferingPolicy) {
            let previousThreshold = startThreshold
            startThreshold = policy.startThresholdSamples
            maxBuffered = policy.maximumBufferedSamples
            if startThreshold > previousThreshold, count < startThreshold {
                playing = false
                renderedPosition = nil
            }
            dropExcess(channels: policy.channels)
        }

        mutating func dropExcess(channels: Int) {
            guard !samples.isEmpty, count > maxBuffered else { return }
            let drop = count - startThreshold
            let aligned = drop - drop % channels
            read = (read + aligned) % samples.count
            count -= aligned
            timeline?.trimOldest(frames: aligned / channels)
            renderedPosition = nil
        }

        mutating func append(_ pcm: [Int16], channels: Int, time: UInt32?) {
            guard !samples.isEmpty, !pcm.isEmpty, pcm.count <= 192_000 * 8,
                  pcm.count % channels == 0 else { return }
            let result = timeline?.append(frameCount: pcm.count / channels, time: time)
            if result?.accepted == false { return }
            if result?.discontinuity == true || result?.metadataLimited == true || count + pcm.count > samples.count {
                renderedPosition = nil
            }
            let size = samples.count
            for sample in pcm {
                let write = (read + count) % size
                samples[write] = Float(sample) / 32768
                if count < size { count += 1 } else { read = (read + 1) % size }
            }
            dropExcess(channels: channels)
        }

        mutating func finishRender(playedFrames: Int, requestedFrames: Int, channels: Int,
                                   hostTime: UInt64?) {
            let played = min(max(0, playedFrames), count / channels)
            let consumed = timeline?.consume(frames: played)
            if played == requestedFrames, played > 0, let consumed,
               let start = consumed.startTime, let end = consumed.endTime, let timeline {
                renderedPosition = AudioRenderPosition(startTime: start, endTime: end, hostTime: hostTime,
                    frameCount: played, sampleRate: timeline.sampleRate, playbackEpoch: generation,
                    timelineEpoch: consumed.epoch)
            } else { renderedPosition = nil }
            read = (read + played * channels) % max(samples.count, 1)
            count -= played * channels
            if playing, played < requestedFrames {
                playing = false
                underruns += 1
            }
        }

        mutating func beginRender(frames: Int, channels: Int, expectedGeneration: UInt64) -> Int? {
            guard generation == expectedGeneration, !samples.isEmpty else { return nil }
            if !playing, count >= startThreshold { playing = true }
            return playing ? min(frames, count / channels) : 0
        }
    }

    public init() {}

    /// (Re)configures for a new stream and starts the engine.
    public func start(channels: Int, sampleRate: Int, minimumLatencyMilliseconds: UInt32 = 0,
                      time: UInt32? = nil) throws {
        guard let policy = AudioBufferingPolicy(channels: channels, sampleRate: sampleRate,
                                                minimumLatencyMilliseconds: minimumLatencyMilliseconds) else {
            throw AudioPlayerError.invalidFormat
        }
        stop()
        self.channels = channels
        self.sampleRate = sampleRate
        let generation = renderGeneration
        ring.withLock { ring in
            ring = Ring(samples: [Float](repeating: 0, count: policy.capacitySamples),
                        startThreshold: policy.startThresholdSamples, maxBuffered: policy.maximumBufferedSamples,
                        timeline: PlaybackTimeline(sampleRate: sampleRate), generation: generation, startTime: time)
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate),
                                         channels: AVAudioChannelCount(channels)) else {
            stop()
            throw AudioPlayerError.invalidFormat
        }
        let channelCount = self.channels
        let node = AVAudioSourceNode(format: format) { [ring] _, timestamp, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            ring.withLock { state in
                let frames = Int(frameCount)
                guard let playable = state.beginRender(frames: frames, channels: channelCount, expectedGeneration: generation) else {
                    for channel in 0..<buffers.count {
                        guard let out = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                        for frame in 0..<frames { out[frame] = 0 }
                    }
                    return
                }
                for channel in 0..<min(channelCount, buffers.count) {
                    guard let out = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    var index = state.read + channel
                    for frame in 0..<frames {
                        if frame < playable {
                            out[frame] = state.samples[index % state.samples.count]
                            index += channelCount
                        } else {
                            out[frame] = 0
                        }
                    }
                }
                let hostTime = timestamp.pointee.mFlags.contains(.hostTimeValid) ? timestamp.pointee.mHostTime : nil
                state.finishRender(playedFrames: playable, requestedFrames: frames, channels: channelCount, hostTime: hostTime)
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
        engine.prepare()
        do { try engine.start() }
        catch { stop(); throw error }
    }

    /// Queues interleaved S16 samples.
    public func enqueue(_ pcm: [Int16], time: UInt32? = nil) {
        ring.withLock { state in
            state.append(pcm, channels: channels, time: time)
        }
    }

    /// Retunes an active queue. This is a buffering target, not output-delay feedback.
    /// A stopped player has no pending policy; pass the latest request to `start`.
    public func setMinimumLatency(milliseconds: UInt32) {
        guard let policy = AudioBufferingPolicy(channels: channels, sampleRate: sampleRate,
                                                minimumLatencyMilliseconds: milliseconds) else { return }
        ring.withLock { state in
            guard !state.samples.isEmpty else { return }
            state.apply(policy)
        }
    }

    public func stop() {
        renderGeneration &+= 1
        engine.stop()
        if let source {
            engine.detach(source)
            self.source = nil
        }
        ring.withLock { $0 = Ring(generation: renderGeneration) }
    }

    public var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = max(0, min(newValue, 1)) }
    }

    /// Buffered audio in milliseconds (diagnostics/tests).
    public var bufferedMilliseconds: Int {
        ring.withLock { $0.count } * 1000 / max(sampleRate * channels, 1)
    }

    public var streamStartTime: UInt32? { ring.withLock { $0.startTime } }

    /// Nil during silence, unknown timing, rebuffering, or after a lifecycle reset.
    public var renderedPosition: AudioRenderPosition? { ring.withLock { $0.renderedPosition } }
}
#endif
