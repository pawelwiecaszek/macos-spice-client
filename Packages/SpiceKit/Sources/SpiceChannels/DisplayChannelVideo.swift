import SpiceCodecs
import SpiceWire

extension DisplayChannel {
    struct VideoStream {
        let generation: UInt64
        var report: VideoStreamReports?
        var create: StreamCreate
        var clip: Clip
        var destination: Rect
        var frames = VideoFrameQueue()
        var unsupported = false
        var unsupportedReported = false
        var lastPresentedTime: UInt32?
        #if canImport(VideoToolbox) && canImport(CoreMedia)
        var decoder: VideoDecoder?
        #endif
    }

    struct QueuedVideoReport {
        let streamGeneration: UInt64
        let activation: UInt64
        let value: StreamReport
    }

    /// Decoded pending frames share a 256 MiB cap in addition to 32 slots per
    /// stream. Codec reference state stays in receive order even for late frames.
    static let maxPendingVideoPixels = 64 * 1024 * 1024

    func createVideoStream(_ create: StreamCreate) throws(WireError) {
        guard hasSurface(create.surfaceID) else { throw .invalidValue("video surface") }
        guard streams.count < Self.maxStreams || streams[create.streamID] != nil else {
            throw .limitExceeded("too many video streams")
        }
        removeVideoStream(create.streamID)
        videoGeneration &+= 1
        var stream = VideoStream(generation: videoGeneration, create: create, clip: create.clip, destination: create.destination)
        switch create.codec {
        case .mjpeg:
            #if !canImport(ImageIO)
            stream.unsupported = true
            #endif
        #if canImport(VideoToolbox) && canImport(CoreMedia)
        case .h264: stream.decoder = VideoDecoder(codec: .h264)
        case .h265: stream.decoder = VideoDecoder(codec: .h265)
        #endif
        default:
            stream.unsupported = true
            warnOnce(DisplayServerMessage.streamCreate.rawValue, "unsupported stream codec \(create.rawCodec)")
        }
        streams[create.streamID] = stream
    }

    func activateVideoReport(_ activate: StreamActivateReport) {
        guard clock?.now != nil, var stream = streams[activate.streamID] else { return }
        videoReportGeneration &+= 1
        stream.report = VideoStreamReports(uniqueID: activate.uniqueID, activation: videoReportGeneration,
                                           maxFrames: activate.maxWindowSize, timeoutMS: activate.timeoutMS)
        stream.unsupportedReported = false
        pendingReports.removeAll { $0.value.streamID == activate.streamID }
        if stream.unsupported { queueUnsupported(streamID: activate.streamID, stream: &stream) }
        streams[activate.streamID] = stream
    }

    func handleStreamData(_ data: StreamData) throws {
        processReadyVideoFrames()
        guard var stream = streams[data.streamID] else { return }
        if let resize = data.resize { stream.destination = resize.destination }
        let ticket = try stream.report?.arrive(time: data.multimediaTime, at: .now)
        var decoded: PixelBuffer?
        var decodeFailed = stream.unsupported
        switch stream.create.codec {
        case .mjpeg:
            #if canImport(ImageIO)
            do { decoded = try JPEGDecoder.decode(data.data) } catch { decodeFailed = true }
            #endif
            break
        case .h264, .h265:
            #if canImport(VideoToolbox) && canImport(CoreMedia)
            do { decoded = try stream.decoder?.decode(data.data) }
            catch { decodeFailed = true; log.debug("video frame decode failed: \(error)") }
            #endif
            break
        default: break
        }
        guard var frame = decoded else {
            if decodeFailed { queueUnsupported(streamID: data.streamID, stream: &stream) }
            // A decoder can legitimately wait for its first key frame. Resolve
            // bookkeeping without misreporting that as an unsupported codec.
            stream.report?.complete(ticket, lateDrop: false, delay: nil)
            takeVideoReports(streamID: data.streamID, stream: &stream)
            streams[data.streamID] = stream
            ensureVideoTimer()
            return
        }
        if !stream.create.isTopDown { frame.flipVertically() }
        videoFrameSequence &+= 1
        let pending = VideoFrameQueue.Frame(time: data.multimediaTime, pixels: frame,
                                            destination: stream.destination, ticket: ticket, sequence: videoFrameSequence)
        let now = clock?.now
        switch VideoFrameTiming.decision(frame: pending.time, now: now) {
        case .present:
            completeVideoFrame(.init(frame: pending, outcome: .present), streamID: data.streamID, stream: &stream, now: now)
        case .late:
            completeVideoFrame(.init(frame: pending, outcome: .late), streamID: data.streamID, stream: &stream, now: now)
        case .farFuture:
            completeVideoFrame(.init(frame: pending, outcome: .farFuture), streamID: data.streamID, stream: &stream, now: now)
        case .wait:
            let room = stream.frames.makeRoom(for: pending.time, now: now ?? pending.time)
            if let old = room.evicted {
                pendingVideoPixels -= old.pixels.pixels.count
                completeVideoFrame(.init(frame: old, outcome: .pressure), streamID: data.streamID, stream: &stream, now: now)
            }
            if room.admit, frame.pixels.count <= Self.maxPendingVideoPixels - pendingVideoPixels {
                stream.frames.append(pending)
                pendingVideoPixels += frame.pixels.count
            } else {
                if frame.pixels.count > Self.maxPendingVideoPixels { queueUnsupported(streamID: data.streamID, stream: &stream) }
                completeVideoFrame(.init(frame: pending, outcome: .pressure), streamID: data.streamID, stream: &stream, now: now)
            }
        }
        takeVideoReports(streamID: data.streamID, stream: &stream)
        streams[data.streamID] = stream
        ensureVideoTimer()
    }

    private func completeVideoFrame(_ completed: VideoFrameQueue.Completed, streamID: UInt32,
                                    stream: inout VideoStream, now: UInt32?) {
        let backwards = stream.lastPresentedTime.map {
            VideoFrameTiming.delay(frame: completed.frame.time, now: $0) < 0
        } ?? false
        stream.report?.complete(completed.frame.ticket, lateDrop: completed.isLateDrop || backwards,
                                delay: now.map { VideoFrameTiming.delay(frame: completed.frame.time, now: $0) })
        guard case .present = completed.outcome else { return }
        guard !backwards else { return }
        stream.lastPresentedTime = completed.frame.time
        let frame = completed.frame
        let base = DisplayBase(surfaceID: stream.create.surfaceID, box: frame.destination, clip: stream.clip)
        mutate(base) {
            $0.copy(from: frame.pixels, sourceArea: frame.pixels.bounds, box: frame.destination,
                    clip: stream.clip, rop: .opPut, scaleMode: .interpolate)
        }
    }

    private func takeVideoReports(streamID: UInt32, stream: inout VideoStream) {
        guard let activation = stream.report?.activation else { return }
        for report in stream.report?.takeReady(streamID: streamID) ?? [] {
            pendingReports.append(QueuedVideoReport(streamGeneration: stream.generation, activation: activation, value: report))
        }
    }

    private func queueUnsupported(streamID: UInt32, stream: inout VideoStream) {
        guard !stream.unsupportedReported, let report = stream.report else { return }
        pendingReports.append(QueuedVideoReport(streamGeneration: stream.generation, activation: report.activation,
            value: StreamReport(streamID: streamID, uniqueID: report.uniqueID, startFrameMMTime: 0,
                               endFrameMMTime: 0, frames: 0, drops: .max, lastFrameDelay: 0)))
        stream.unsupportedReported = true
    }

    func processReadyVideoFrames() {
        guard !closed else { return }
        let now = clock?.now
        var presentations: [(id: UInt32, generation: UInt64, frame: VideoFrameQueue.Completed)] = []
        for id in Array(streams.keys) {
            guard var stream = streams[id] else { continue }
            for completed in stream.frames.drain(now: now) {
                pendingVideoPixels -= completed.frame.pixels.pixels.count
                if case .present = completed.outcome {
                    presentations.append((id, stream.generation, completed))
                } else { completeVideoFrame(completed, streamID: id, stream: &stream, now: now) }
            }
            stream.report?.expire(at: .now)
            takeVideoReports(streamID: id, stream: &stream)
            streams[id] = stream
        }
        // Different streams can target one surface. Commit due frames by time,
        // then receive order, rather than Dictionary iteration order.
        presentations.sort { left, right in
            if let now {
                let a = VideoFrameTiming.delay(frame: left.frame.frame.time, now: now)
                let b = VideoFrameTiming.delay(frame: right.frame.frame.time, now: now)
                if a != b { return a < b }
            }
            return Int64(bitPattern: left.frame.frame.sequence &- right.frame.frame.sequence) < 0
        }
        for presentation in presentations {
            guard var stream = streams[presentation.id], stream.generation == presentation.generation else { continue }
            completeVideoFrame(presentation.frame, streamID: presentation.id, stream: &stream, now: now)
            takeVideoReports(streamID: presentation.id, stream: &stream)
            streams[presentation.id] = stream
        }
    }

    /// Also used by deterministic wire tests after advancing an injected clock.
    func processVideoDeadlines() async throws {
        processReadyVideoFrames()
        scheduleFlush()
        try await sendVideoReports()
    }

    func sendVideoReports() async throws {
        let ready = pendingReports
        pendingReports.removeAll(keepingCapacity: true)
        for report in ready {
            guard !closed, let stream = streams[report.value.streamID], stream.generation == report.streamGeneration else { continue }
            // A reactivation can reuse the server's unique_id. Our own activation
            // identity prevents an old pending report authorizing the new window.
            guard stream.report?.activation == report.activation else { continue }
            var value = report.value
            value.audioDelay = clock?.audioDelayMilliseconds ?? .max
            try await connection.send(DisplayClientEncoder.streamReport(value))
        }
    }

    private var videoHasWork: Bool {
        streams.values.contains { !$0.frames.isEmpty || $0.report?.hasWork == true }
    }

    private func ensureVideoTimer() {
        guard !closed, videoTimer == nil, videoHasWork else { return }
        videoTimerGeneration &+= 1
        let generation = videoTimerGeneration
        videoTimer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                guard let self, await self.videoTick(generation: generation) else { return }
            }
        }
    }

    private func videoTick(generation: UInt64) async -> Bool {
        guard !closed, videoTimerGeneration == generation else { return false }
        do { try await processVideoDeadlines() }
        catch {
            await close()
            return false
        }
        guard !closed, videoTimerGeneration == generation else { return false }
        if !videoHasWork { videoTimer = nil; return false }
        return true
    }

    func removeVideoStream(_ id: UInt32) {
        if let removed = streams.removeValue(forKey: id) { pendingVideoPixels -= removed.frames.pixelCount }
        pendingReports.removeAll { $0.value.streamID == id }
    }

    func removeVideoStreams(forSurface id: UInt32) {
        for streamID in streams.keys.filter({ streams[$0]?.create.surfaceID == id }) { removeVideoStream(streamID) }
    }

    func endVideoStreams() {
        videoTimerGeneration &+= 1
        videoTimer?.cancel()
        videoTimer = nil
        streams.removeAll()
        pendingVideoPixels = 0
        pendingReports.removeAll()
    }
}
