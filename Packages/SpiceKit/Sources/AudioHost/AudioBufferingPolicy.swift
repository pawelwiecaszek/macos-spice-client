/// Bounded queue targets for guest playback, separate from measured output delay.
/// Server requests above 750 ms are capped by local resource/latency policy.
public struct AudioBufferingPolicy: Sendable, Equatable {
    public let channels: Int
    public let sampleRate: Int
    public let minimumBufferMilliseconds: Int
    public let maximumBufferMilliseconds: Int
    public let startThresholdSamples: Int
    public let maximumBufferedSamples: Int
    public let capacitySamples: Int

    public init?(channels: Int, sampleRate: Int, minimumLatencyMilliseconds: UInt32 = 0) {
        guard (1...8).contains(channels), (8_000...192_000).contains(sampleRate) else { return nil }
        self.channels = channels
        self.sampleRate = sampleRate
        minimumBufferMilliseconds = max(60, Int(min(minimumLatencyMilliseconds, 750)))
        maximumBufferMilliseconds = max(250, minimumBufferMilliseconds + 190)
        // Round frames upward before interleaving, so fractional-rate thresholds
        // cannot split a channel frame or undershoot the requested minimum.
        startThresholdSamples = ((sampleRate * minimumBufferMilliseconds + 999) / 1000) * channels
        maximumBufferedSamples = ((sampleRate * maximumBufferMilliseconds + 999) / 1000) * channels
        capacitySamples = sampleRate * channels // One second, independent of the request.
    }
}
