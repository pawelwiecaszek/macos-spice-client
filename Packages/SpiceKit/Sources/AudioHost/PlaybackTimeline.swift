/// Bounded metadata for a PCM FIFO. Times describe half-open frame boundaries in
/// the server's wrapping millisecond time base, not measured device presentation.
public struct PlaybackTimeline: Sendable {
    public struct AppendResult: Sendable, Equatable {
        public let accepted: Bool
        public let trimmedFrames: Int
        public let discontinuity: Bool
        public let metadataLimited: Bool
    }

    public struct Consumption: Sendable, Equatable {
        public let frameCount: Int
        public let startTime: UInt32?
        public let endTime: UInt32?
        public let epoch: UInt64
    }

    private struct Segment: Sendable {
        var firstFrame: Int64
        var frames: Int
        let anchor: UInt32?
        let epoch: UInt64
    }

    public let sampleRate: Int
    public let maxFrames: Int
    public let maxSegments: Int
    public private(set) var queuedFrames = 0
    public private(set) var epoch: UInt64 = 0
    private var segments: [Segment?]
    private var head = 0
    private var segmentCount = 0
    private var anchor: UInt32?
    private var writtenFrames: Int64 = 0

    /// Capacity is at most one second of audio. Storage is allocated once, never
    /// per rendered frame. Invalid configuration fails before allocation.
    public init?(sampleRate: Int, maxFrames: Int? = nil, maxSegments: Int = 2048) {
        guard (8_000...192_000).contains(sampleRate), (1...2048).contains(maxSegments) else { return nil }
        let capacity = maxFrames ?? sampleRate
        guard (1...sampleRate).contains(capacity) else { return nil }
        self.sampleRate = sampleRate
        self.maxFrames = capacity
        self.maxSegments = maxSegments
        segments = Array(repeating: nil, count: maxSegments)
    }

    /// Adds packet metadata and analytically discards excess oldest frames, just
    /// as the PCM ring overwrites them. Oversized valid packets can discard their
    /// own prefix. Counts beyond Int32.max reject atomically; no frame walk occurs.
    @discardableResult
    public mutating func append(frameCount: Int, time: UInt32?) -> AppendResult {
        guard (0...Int(Int32.max)).contains(frameCount) else {
            return AppendResult(accepted: false, trimmedFrames: 0, discontinuity: false, metadataLimited: false)
        }
        guard frameCount > 0 else {
            return AppendResult(accepted: true, trimmedFrames: 0, discontinuity: false, metadataLimited: false)
        }
        var discontinuity = false
        if let time {
            if let anchor {
                let expected = timestamp(anchor: anchor, frame: writtenFrames)
                let difference = Int64(Int32(bitPattern: time &- expected))
                if difference < -1 || difference > 1 || writtenFrames > Int64.max - Int64(frameCount) {
                    epoch &+= 1
                    self.anchor = time
                    writtenFrames = 0
                    collapseToUnknown()
                    discontinuity = true
                }
            } else {
                epoch &+= 1
                anchor = time
                writtenFrames = 0
            }
        } else {
            // Keep earlier known regions usable, but never interpolate across an
            // untimed packet. The following timed packet establishes a new epoch.
            if anchor != nil { epoch &+= 1 }
            anchor = nil
            writtenFrames = 0
        }
        let excess = max(0, queuedFrames + frameCount - maxFrames)
        let removed = trimOldest(frames: excess)
        let prefix = excess - removed
        let retained = frameCount - prefix
        let segment = Segment(firstFrame: writtenFrames + Int64(prefix), frames: retained,
                              anchor: anchor, epoch: epoch)
        writtenFrames += Int64(frameCount)
        queuedFrames += retained
        var limited = false
        if segmentCount > 0 {
            let tail = (head + segmentCount - 1) % maxSegments
            if var previous = segments[tail], previous.anchor == segment.anchor, previous.epoch == segment.epoch,
               previous.anchor == nil || previous.firstFrame + Int64(previous.frames) == segment.firstFrame {
                previous.frames += retained
                segments[tail] = previous
                return AppendResult(accepted: true, trimmedFrames: excess,
                                    discontinuity: discontinuity, metadataLimited: false)
            }
        }
        if segmentCount == maxSegments {
            // Losing a timestamp must not lose its PCM/frame correspondence. One
            // unknown region represents the complete retained queue; a later fresh
            // timed packet can restore estimates after this region is consumed.
            epoch &+= 1
            anchor = nil
            writtenFrames = 0
            collapseToUnknown()
            limited = true
        } else {
            segments[(head + segmentCount) % maxSegments] = segment
            segmentCount += 1
        }
        return AppendResult(accepted: true, trimmedFrames: excess,
                            discontinuity: discontinuity, metadataLimited: limited)
    }

    /// Drops queued frames without treating them as presented audio.
    @discardableResult
    public mutating func trimOldest(frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        let removed = min(frames, queuedFrames)
        var remaining = removed
        while remaining > 0, var segment = segments[head] {
            let count = min(remaining, segment.frames)
            if segment.anchor != nil { segment.firstFrame += Int64(count) }
            segment.frames -= count
            remaining -= count
            if segment.frames == 0 {
                segments[head] = nil
                head = (head + 1) % maxSegments
                segmentCount -= 1
            } else { segments[head] = segment }
        }
        queuedFrames -= removed
        return removed
    }

    /// Consumes actual PCM frames. A range crossing unknown metadata or an epoch
    /// boundary has no estimate; it is never reported as falsely continuous.
    public mutating func consume(frames: Int) -> Consumption? {
        guard frames > 0, queuedFrames > 0, let first = segments[head] else { return nil }
        let count = min(frames, queuedFrames)
        var remaining = count, index = head
        var valid = first.anchor != nil, endFrame = first.firstFrame
        while remaining > 0, let segment = segments[index] {
            let taken = min(remaining, segment.frames)
            valid = valid && segment.anchor == first.anchor && segment.epoch == first.epoch
            endFrame = segment.firstFrame + Int64(taken)
            remaining -= taken
            index = (index + 1) % maxSegments
        }
        let start = valid ? first.anchor.map { timestamp(anchor: $0, frame: first.firstFrame) } : nil
        let end = valid ? first.anchor.map { timestamp(anchor: $0, frame: endFrame) } : nil
        _ = trimOldest(frames: count)
        return Consumption(frameCount: count, startTime: start, endTime: end, epoch: first.epoch)
    }

    /// Starts a fresh stream epoch, including after stop, format or route changes.
    public mutating func reset() {
        for index in segments.indices { segments[index] = nil }
        head = 0
        segmentCount = 0
        queuedFrames = 0
        anchor = nil
        writtenFrames = 0
        epoch &+= 1
    }

    private mutating func collapseToUnknown() {
        head = 0
        segmentCount = queuedFrames > 0 ? 1 : 0
        if queuedFrames > 0 {
            segments[0] = Segment(firstFrame: 0, frames: queuedFrames, anchor: nil, epoch: epoch)
        }
    }

    private func timestamp(anchor: UInt32, frame: Int64) -> UInt32 {
        let rate = Int64(sampleRate)
        // Divide before multiplying: even long-lived epochs cannot overflow by
        // multiplying a cumulative frame count by one thousand.
        let milliseconds = (frame / rate) * 1000 + (frame % rate) * 1000 / rate
        return anchor &+ UInt32(truncatingIfNeeded: milliseconds)
    }
}
