#if canImport(AVFoundation)
import AVFoundation
import Synchronization

/// Plays the guest's audio: interleaved S16 PCM goes into a jitter buffer that an
/// `AVAudioSourceNode` drains on the audio thread.
///
/// Playback starts once ~60 ms are buffered, pauses (silence) on underrun until it has
/// re-buffered, and drops the oldest audio when more than ~250 ms pile up, keeping latency
/// low over WAN links.
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
    }

    public init() {}

    /// (Re)configures for a new stream and starts the engine.
    public func start(channels: Int, sampleRate: Int) throws {
        stop()
        self.channels = max(1, min(channels, 8))
        self.sampleRate = sampleRate
        let capacity = sampleRate * self.channels  // 1 s
        ring.withLock { ring in
            ring = Ring(samples: [Float](repeating: 0, count: capacity), startThreshold: sampleRate * self.channels * 60 / 1000,
                        maxBuffered: sampleRate * self.channels * 250 / 1000)
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate),
                                         channels: AVAudioChannelCount(self.channels)) else { return }
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
        try engine.start()
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
            // Too much latency piled up (e.g. after a network stall): drop the oldest.
            if state.count > state.maxBuffered {
                let drop = state.count - state.startThreshold
                let aligned = drop - drop % max(channels, 1)
                state.read = (state.read + aligned) % size
                state.count -= aligned
            }
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
