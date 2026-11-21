import SpiceCodecs
import SpiceWire

/// Local scheduling limits, not protocol-mandated lateness tolerances.
enum VideoFrameTiming {
    enum Decision: Equatable { case present, wait(milliseconds: Int), late, farFuture }

    static func delay(frame: UInt32, now: UInt32) -> Int32 { Int32(bitPattern: frame &- now) }

    static func decision(frame: UInt32, now: UInt32?) -> Decision {
        guard let now else { return .present }
        let difference = delay(frame: frame, now: now)
        if difference < -100 { return .late }
        if difference > 2500 { return .farFuture }
        return difference > 0 ? .wait(milliseconds: Int(difference)) : .present
    }
}

struct VideoFrameQueue {
    static let capacity = 32

    struct Frame {
        let time: UInt32
        let pixels: PixelBuffer
        let destination: Rect
        let ticket: VideoStreamReports.Ticket?
        let sequence: UInt64
        init(time: UInt32, pixels: PixelBuffer, destination: Rect, ticket: VideoStreamReports.Ticket?, sequence: UInt64 = 0) {
            self.time = time; self.pixels = pixels; self.destination = destination
            self.ticket = ticket; self.sequence = sequence
        }
    }

    enum Outcome { case present, late, superseded, farFuture, pressure }
    struct Completed {
        let frame: Frame
        let outcome: Outcome
        var isLateDrop: Bool {
            switch outcome { case .late, .superseded: true; default: false }
        }
    }

    private(set) var frames: [Frame] = []
    var pixelCount: Int { frames.reduce(0) { $0 + $1.pixels.pixels.count } }
    var isEmpty: Bool { frames.isEmpty }

    mutating func makeRoom(for time: UInt32, now: UInt32) -> (admit: Bool, evicted: Frame?) {
        guard frames.count == Self.capacity else { return (true, nil) }
        guard let farthest = frames.indices.max(by: {
            VideoFrameTiming.delay(frame: frames[$0].time, now: now) < VideoFrameTiming.delay(frame: frames[$1].time, now: now)
        }) else { return (false, nil) }
        // Keeping the nearest deadlines guarantees progress even when audio's
        // presentation delay exceeds the queue's frame-count/memory capacity.
        guard VideoFrameTiming.delay(frame: time, now: now) <=
              VideoFrameTiming.delay(frame: frames[farthest].time, now: now) else { return (false, nil) }
        return (true, frames.remove(at: farthest))
    }

    mutating func append(_ frame: Frame) { frames.append(frame) }

    /// Inspect bounded slots: an out-of-order future timestamp cannot block a
    /// newer due frame. Older due frames are superseded, not painted backwards.
    mutating func drain(now: UInt32?) -> [Completed] {
        var remaining: [Frame] = [], completed: [Completed] = []
        var lastDue: Int?
        if let now {
            for index in frames.indices where VideoFrameTiming.decision(frame: frames[index].time, now: now) == .present {
                if lastDue == nil || VideoFrameTiming.delay(frame: frames[index].time, now: now) >=
                    VideoFrameTiming.delay(frame: frames[lastDue ?? index].time, now: now) { lastDue = index }
            }
        }
        for (index, frame) in frames.enumerated() {
            switch VideoFrameTiming.decision(frame: frame.time, now: now) {
            case .wait: remaining.append(frame)
            case .present:
                completed.append(Completed(frame: frame, outcome: lastDue == nil || index == lastDue ? .present : .superseded))
            case .late: completed.append(Completed(frame: frame, outcome: .late))
            case .farFuture: completed.append(Completed(frame: frame, outcome: .farFuture))
            }
        }
        frames = remaining
        return completed
    }
}
