/// An estimate based on the output node's reported presentation latency. It is
/// not a physical measurement that samples have reached the listener.
public struct AudioPresentationEstimate: Sendable, Equatable {
    public let serverTime: UInt32
    public let outputDelayMilliseconds: UInt32

    /// `hostTimeDeltaSeconds` is current host time minus the latest block's
    /// first-frame render host time. `continuousRenderElapsedSeconds` instead
    /// measures from the first block in the uninterrupted playback interval.
    /// Keeping those ages separate allows a fresh future render block while an
    /// earlier block is already audible through a long output pipeline.
    public static func calculate(serverStart: UInt32, hostTimeDeltaSeconds: Double,
                                 outputLatencySeconds: Double,
                                 continuousRenderElapsedSeconds: Double) -> Self? {
        guard hostTimeDeltaSeconds.isFinite, outputLatencySeconds.isFinite,
              continuousRenderElapsedSeconds.isFinite,
              (-0.1...0.25).contains(hostTimeDeltaSeconds),
              outputLatencySeconds > 0, outputLatencySeconds <= 1,
              continuousRenderElapsedSeconds >= outputLatencySeconds else { return nil }

        // Apply the downstream/device latency exactly once. A latest HAL render
        // block may be ahead of now, so this offset must stay signed until wrap.
        let offset = Int64(((hostTimeDeltaSeconds - outputLatencySeconds) * 1000).rounded(.down))
        let delay = UInt32((outputLatencySeconds * 1000).rounded(.up))
        return Self(serverTime: serverStart &+ UInt32(truncatingIfNeeded: offset),
                    outputDelayMilliseconds: delay)
    }
}
