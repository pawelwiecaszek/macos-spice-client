import SpiceWire

/// Pinned spice.proto:985–1006 counts arrivals, then late-arrival drops. A
/// window closes by count/time but waits for its bounded pending decisions.
struct VideoStreamReports {
    struct Ticket {
        let activation: UInt64
        let window: UInt64
        let sequence: UInt32
    }
    private struct Window {
        let id: UInt64
        let started: ContinuousClock.Instant
        let firstTime: UInt32
        var lastTime: UInt32
        var frames: UInt32 = 0
        var pending: UInt32 = 0
        var drops: UInt32 = 0
        var delay: Int32?
        var closed = false
    }

    let uniqueID: UInt32
    let activation: UInt64
    private let maxFrames: UInt32
    private let timeout: Duration
    private var windows: [Window] = []
    private var nextWindow: UInt64 = 0

    init(uniqueID: UInt32, activation: UInt64, maxFrames: UInt32, timeoutMS: UInt32) {
        self.uniqueID = uniqueID
        self.activation = activation
        self.maxFrames = max(1, maxFrames)
        timeout = .milliseconds(Int(max(1, min(timeoutMS, 60_000))))
    }

    var hasWork: Bool { !windows.isEmpty }

    mutating func arrive(time: UInt32, at now: ContinuousClock.Instant) throws(WireError) -> Ticket {
        expire(at: now)
        if windows.last?.closed != false {
            guard windows.count < VideoFrameQueue.capacity + 2 else { throw .limitExceeded("video report windows") }
            nextWindow &+= 1
            windows.append(Window(id: nextWindow, started: now, firstTime: time, lastTime: time))
        }
        let index = windows.count - 1
        windows[index].frames += 1
        windows[index].pending += 1
        windows[index].lastTime = time
        if windows[index].frames >= maxFrames { windows[index].closed = true }
        return Ticket(activation: activation, window: windows[index].id, sequence: windows[index].frames)
    }

    mutating func complete(_ ticket: Ticket?, lateDrop: Bool, delay: Int32?) {
        guard let ticket, ticket.activation == activation,
              let index = windows.firstIndex(where: { $0.id == ticket.window }), windows[index].pending > 0 else { return }
        windows[index].pending -= 1
        if lateDrop { windows[index].drops += 1 }
        if ticket.sequence == windows[index].frames { windows[index].delay = delay }
    }

    mutating func expire(at now: ContinuousClock.Instant) {
        for index in windows.indices where now - windows[index].started >= timeout { windows[index].closed = true }
    }

    mutating func takeReady(streamID: UInt32) -> [StreamReport] {
        var reports: [StreamReport] = []
        while let first = windows.first, first.closed, first.pending == 0 {
            windows.removeFirst()
            // An unknown multimedia clock cannot yield a measured delay of zero.
            guard let delay = first.delay else { continue }
            reports.append(StreamReport(streamID: streamID, uniqueID: uniqueID,
                startFrameMMTime: first.firstTime, endFrameMMTime: first.lastTime,
                frames: first.frames, drops: first.drops, lastFrameDelay: delay))
        }
        // Future frames may hold earlier windows open. Coalesce completed tails
        // rather than accumulating one window per rejected incoming frame.
        var index = 0
        while index + 1 < windows.count {
            let right = windows[index + 1]
            var left = windows[index]
            let sum = left.frames.addingReportingOverflow(right.frames)
            if left.closed, right.closed, left.pending == 0, right.pending == 0, !sum.overflow {
                left.frames = sum.partialValue
                left.drops += right.drops
                left.lastTime = right.lastTime
                left.delay = right.delay
                windows[index] = left
                windows.remove(at: index + 1)
            } else { index += 1 }
        }
        return reports
    }
}
