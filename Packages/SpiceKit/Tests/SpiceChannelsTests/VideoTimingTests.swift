import Testing
@testable import SpiceChannels
import SpiceCodecs
import SpiceWire

struct VideoTimingTests {
    @Test func deadlinesUseWrappingSignedTimeAndExplicitLocalBounds() {
        #expect(VideoFrameTiming.decision(frame: 0, now: nil) == .present)
        #expect(VideoFrameTiming.decision(frame: 100, now: 100) == .present)
        #expect(VideoFrameTiming.decision(frame: 200, now: 100) == .wait(milliseconds: 100))
        #expect(VideoFrameTiming.decision(frame: 0, now: 100) == .present)
        #expect(VideoFrameTiming.decision(frame: 0, now: 101) == .late)
        #expect(VideoFrameTiming.decision(frame: 2601, now: 100) == .farFuture)
        #expect(VideoFrameTiming.decision(frame: 4, now: UInt32.max - 5) == .wait(milliseconds: 10))
        #expect(VideoFrameTiming.delay(frame: UInt32.max - 5, now: 4) == -10)
    }

    @Test func newestDueTimestampWinsEvenWhenArrivalOrderIsDifferent() {
        var queue = VideoFrameQueue()
        for time: UInt32 in [130,100,90] { queue.append(frame(time)) }
        let completed = queue.drain(now: 100)
        #expect(queue.frames.map(\.time) == [130])
        #expect(completed.map { $0.frame.time } == [100,90])
        guard completed.count == 2 else { return }
        if case .present = completed[0].outcome { } else { Issue.record("Newest due frame must present") }
        #expect(completed[1].isLateDrop)
        #expect(queue.drain(now: 130).count == 1 && queue.isEmpty)
    }

    @Test func capacityPressureAndFarFutureHaveDifferentDropSemantics() {
        var queue = VideoFrameQueue()
        for time in 1...VideoFrameQueue.capacity { queue.append(frame(UInt32(time * 10))) }
        let rejected = queue.makeRoom(for: 1000, now: 0)
        #expect(!rejected.admit && rejected.evicted == nil)
        let room = queue.makeRoom(for: 5, now: 0)
        #expect(room.admit && room.evicted?.time == UInt32(VideoFrameQueue.capacity * 10))
        queue.append(frame(5))
        #expect(queue.frames.count == VideoFrameQueue.capacity && queue.pixelCount == VideoFrameQueue.capacity)
        let pressure = VideoFrameQueue.Completed(frame: frame(100), outcome: .pressure)
        #expect(!pressure.isLateDrop)
        var far = VideoFrameQueue(); far.append(frame(5000))
        #expect(far.drain(now: 0).first?.isLateDrop == false)
        #expect(far.isEmpty)
    }

    @Test func noClockPresentsReceiveOrderWithoutFabricatingDelay() {
        var queue = VideoFrameQueue()
        queue.append(frame(2)); queue.append(frame(1))
        let completed = queue.drain(now: nil)
        #expect(completed.map { $0.frame.time } == [2,1])
        #expect(completed.allSatisfy { !$0.isLateDrop } && queue.isEmpty)
    }

    @Test func reportCountsArrivalsAndWaitsForPendingTerminalDecisions() throws {
        let now = ContinuousClock.now
        var reports = VideoStreamReports(uniqueID: 7, activation: 1, maxFrames: 2, timeoutMS: 20)
        let first = try reports.arrive(time: 110, at: now)
        let last = try reports.arrive(time: 120, at: now)
        reports.complete(last, lateDrop: false, delay: 5)
        #expect(reports.takeReady(streamID: 9).isEmpty)
        reports.complete(first, lateDrop: true, delay: -100)
        let result = try #require(reports.takeReady(streamID: 9).first)
        #expect(result.streamID == 9 && result.uniqueID == 7)
        #expect(result.frames == 2 && result.drops == 1)
        #expect(result.startFrameMMTime == 110 && result.endFrameMMTime == 120 && result.lastFrameDelay == 5)
        #expect(!reports.hasWork)
    }

    @Test func timeoutClosesReportsWithoutWaitingForAnotherPacket() throws {
        let now = ContinuousClock.now
        var reports = VideoStreamReports(uniqueID: 7, activation: 1, maxFrames: 100, timeoutMS: 20)
        let ticket = try reports.arrive(time: 110, at: now)
        reports.complete(ticket, lateDrop: false, delay: 0)
        #expect(reports.takeReady(streamID: 9).isEmpty)
        reports.expire(at: now.advanced(by: .milliseconds(20)))
        #expect(reports.takeReady(streamID: 9).first?.frames == 1)
        #expect(!reports.hasWork)
    }

    @Test func reportActivationIdentityRejectsStaleCompletions() throws {
        let now = ContinuousClock.now
        var old = VideoStreamReports(uniqueID: 7, activation: 1, maxFrames: 1, timeoutMS: 20)
        let stale = try old.arrive(time: 100, at: now)
        var fresh = VideoStreamReports(uniqueID: 7, activation: 2, maxFrames: 1, timeoutMS: 20)
        let current = try fresh.arrive(time: 200, at: now)
        fresh.complete(stale, lateDrop: true, delay: -100)
        #expect(fresh.takeReady(streamID: 9).isEmpty)
        fresh.complete(current, lateDrop: false, delay: 0)
        #expect(fresh.takeReady(streamID: 9).first?.drops == 0)
    }

    @Test func unknownClockDiscardsReportInsteadOfInventingZeroDelay() throws {
        var reports = VideoStreamReports(uniqueID: 7, activation: 1, maxFrames: 1, timeoutMS: 20)
        let ticket = try reports.arrive(time: 110, at: .now)
        reports.complete(ticket, lateDrop: false, delay: nil)
        #expect(reports.takeReady(streamID: 9).isEmpty && !reports.hasWork)
    }

    @Test func unresolvedReportWindowsAreBounded() throws {
        var reports = VideoStreamReports(uniqueID: 7, activation: 1, maxFrames: 1, timeoutMS: 20)
        for time in 0..<(VideoFrameQueue.capacity + 2) { _ = try reports.arrive(time: UInt32(time), at: .now) }
        #expect(throws: WireError.limitExceeded("video report windows")) { _ = try reports.arrive(time: 6, at: .now) }
    }

    @Test func sustainedArrivalsCannotEvictEveryNearestDeadline() {
        var queue = VideoFrameQueue()
        var presented = 0
        for tick in 0..<200 {
            let now = UInt32(tick * 10)
            for completed in queue.drain(now: now) {
                if case .present = completed.outcome { presented += 1 }
            }
            let timestamp = now + 750
            let room = queue.makeRoom(for: timestamp, now: now)
            if room.admit { queue.append(frame(timestamp)) }
            #expect(queue.frames.count <= VideoFrameQueue.capacity)
        }
        #expect(presented > 0)
    }

    @Test func completedReportTailsStayBoundedBehindFutureFrame() throws {
        let now = ContinuousClock.now
        var reports = VideoStreamReports(uniqueID: 7, activation: 1, maxFrames: 1, timeoutMS: 20)
        let waiting = try reports.arrive(time: 100, at: now)
        for time: UInt32 in 101...500 {
            let ticket = try reports.arrive(time: time, at: now)
            reports.complete(ticket, lateDrop: false, delay: 10)
            #expect(reports.takeReady(streamID: 9).isEmpty)
        }
        reports.complete(waiting, lateDrop: false, delay: 0)
        let completed = reports.takeReady(streamID: 9)
        #expect(completed.reduce(UInt32(0)) { $0 + $1.frames } == 401)
        #expect(!reports.hasWork)
    }

    private func frame(_ time: UInt32) -> VideoFrameQueue.Frame {
        .init(time: time, pixels: PixelBuffer(width: 1, height: 1),
              destination: .init(x: 0, y: 0, width: 1, height: 1), ticket: nil)
    }
}
