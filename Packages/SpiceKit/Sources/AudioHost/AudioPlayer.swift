#if canImport(AVFoundation)
import AVFoundation
import Synchronization

public enum AudioPlayerError: Error, Sendable {
    case invalidFormat
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

        mutating func apply(_ policy: AudioBufferingPolicy) {
            let previousThreshold = startThreshold
            startThreshold = policy.startThresholdSamples
            maxBuffered = policy.maximumBufferedSamples
            if startThreshold > previousThreshold, count < startThreshold { playing = false }
            dropExcess(channels: policy.channels)
        }

        mutating func dropExcess(channels: Int) {
            guard !samples.isEmpty, count > maxBuffered else { return }
            let drop = count - startThreshold
            let aligned = drop - drop % channels
            read = (read + aligned) % samples.count
            count -= aligned
        }
    }

    public init() {}

    /// (Re)configures for a new stream and starts the engine.
    public func start(channels: Int, sampleRate: Int, minimumLatencyMilliseconds: UInt32 = 0) throws {
        guard let policy = AudioBufferingPolicy(channels: channels, sampleRate: sampleRate,
                                                minimumLatencyMilliseconds: minimumLatencyMilliseconds) else {
            throw AudioPlayerError.invalidFormat
        }
        stop()
        self.channels = channels
        self.sampleRate = sampleRate
        ring.withLock { ring in
            ring = Ring(samples: [Float](repeating: 0, count: policy.capacitySamples),
                        startThreshold: policy.startThresholdSamples, maxBuffered: policy.maximumBufferedSamples)
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate),
                                         channels: AVAudioChannelCount(channels)) else {
            stop()
            throw AudioPlayerError.invalidFormat
        }
        let channelCount = self.channels
        let node = AVAudioSourceNode(format: format) { [ring] _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            ring.withLock { state in
                let frames = Int(frameCount)
                let available = state.count / channelCount
                if !state.playing, state.count >= state.startThreshold { state.playing = true }
                let playable = state.playing ? min(frames, available) : 0
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
                state.read = (state.read + playable * channelCount) % max(state.samples.count, 1)
                state.count -= playable * channelCount
                if state.playing, playable < frames {
                    state.playing = false  // underrun: re-buffer before resuming
                    state.underruns += 1
                }
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
    public func enqueue(_ pcm: [Int16]) {
        ring.withLock { state in
            guard !state.samples.isEmpty else { return }
            let size = state.samples.count
            for sample in pcm {
                let write = (state.read + state.count) % size
                state.samples[write] = Float(sample) / 32768
                if state.count < size { state.count += 1 } else { state.read = (state.read + 1) % size }
            }
            state.dropExcess(channels: channels)
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
        engine.stop()
        if let source {
            engine.detach(source)
            self.source = nil
        }
        ring.withLock { $0 = Ring() }
    }

    public var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = max(0, min(newValue, 1)) }
    }

    /// Buffered audio in milliseconds (diagnostics/tests).
    public var bufferedMilliseconds: Int {
        ring.withLock { $0.count } * 1000 / max(sampleRate * channels, 1)
    }
}
#endif
