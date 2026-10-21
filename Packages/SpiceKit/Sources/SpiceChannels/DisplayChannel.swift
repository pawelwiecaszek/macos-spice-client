import Synchronization
import SpiceCodecs
import SpiceWire

/// Backpressure between the display channel and the renderer: at most `limit` surface
/// updates are queued; further damage is merged into the pending dirty rectangle (so no
/// pixels are lost) until the consumer catches up.
public final class DisplayUpdateCredit: Sendable {
    public let limit: Int
    private let queued = Mutex(0)

    public init(limit: Int = 3) { self.limit = limit }

    /// Called by the consumer after applying one `.update`.
    public func consumed() {
        queued.withLock { $0 = max(0, $0 - 1) }
    }

    func tryAcquire() -> Bool {
        queued.withLock { count in
            guard count < limit else { return false }
            count += 1
            return true
        }
    }
}

/// A changed region of a surface, with its pixels (premultiplied BGRA, top-down, tightly
/// packed `width × height`).
public struct SurfaceUpdate: Sendable {
    public var surfaceID: UInt32
    public var rect: Rect
    public var pixels: [UInt32]

    public init(surfaceID: UInt32, rect: Rect, pixels: [UInt32]) {
        self.surfaceID = surfaceID
        self.rect = rect
        self.pixels = pixels
    }
}

/// Events for the renderer.
public enum DisplayEvent: Sendable {
    /// The primary surface was (re)created; clear the presentation texture to this size.
    case primarySurfaceCreated(surfaceID: UInt32, width: Int, height: Int)
    case primarySurfaceDestroyed(surfaceID: UInt32)
    case update(SurfaceUpdate)
    case monitorsConfig([MonitorHead])
}

/// Display channel: maintains CPU-side surfaces and emits `SurfaceUpdate`s for the
/// primary surface. Image decoding happens here, off the main thread.
public actor DisplayChannel {
    public static let pixmapCacheBudget = 16 * 1024 * 1024  // pixels
    public static let glzWindowSize: Int32 = 8 * 1024 * 1024  // pixels (32 MiB of dictionary)

    /// Video codecs this Mac decodes, in preference order (hardware H.264/H.265 first).
    public static var videoCodecs: [VideoCodecType] {
        var codecs: [VideoCodecType] = []
        #if canImport(VideoToolbox) && canImport(CoreMedia)
        if VideoDecoder.hardwareSupported(.h264) { codecs.append(.h264) }
        if VideoDecoder.hardwareSupported(.h265) { codecs.append(.h265) }
        #endif
        #if canImport(ImageIO)
        codecs.append(.mjpeg)
        #endif
        return codecs
    }

    /// Channel caps the client advertises.
    public static var capabilities: CapabilitySet {
        var bits: [Int] = [
            DisplayCapability.sizedStream.rawValue,
            DisplayCapability.streamReport.rawValue,
            DisplayCapability.monitorsConfig.rawValue,
            DisplayCapability.prefCompression.rawValue,
            DisplayCapability.lz4Compression.rawValue,
            DisplayCapability.multiCodec.rawValue,
        ]
        bits.append(DisplayCapability.prefVideoCodecType.rawValue)
        for codec in videoCodecs {
            switch codec {
            case .mjpeg: bits.append(DisplayCapability.codecMJPEG.rawValue)
            case .h264: bits.append(DisplayCapability.codecH264.rawValue)
            case .h265: bits.append(DisplayCapability.codecH265.rawValue)
            case .vp8: bits.append(DisplayCapability.codecVP8.rawValue)
            case .vp9: bits.append(DisplayCapability.codecVP9.rawValue)
            }
        }
        return CapabilitySet(bits: bits)
    }

    struct SurfaceState {
        var buffer: PixelBuffer
        var format: SurfaceFormat?
        var isPrimary: Bool
    }

    /// Statistics collected for SPICE_MSGC_DISPLAY_STREAM_REPORT (lets the server adapt the
    /// bitrate when frames arrive late or fail to decode).
    struct ReportWindow {
        var uniqueID: UInt32
        var maxFrames: UInt32
        var timeout: Duration
        var started: ContinuousClock.Instant?
        var startFrameTime: UInt32 = 0
        var endFrameTime: UInt32 = 0
        var frames: UInt32 = 0
        var drops: UInt32 = 0
        var lastDelay: Int32 = 0

        init(uniqueID: UInt32, maxFrames: UInt32, timeout: Duration) {
            self.uniqueID = uniqueID
            self.maxFrames = maxFrames
            self.timeout = timeout
        }
    }

    struct VideoStream {
        var report: ReportWindow?
        var create: StreamCreate
        var clip: Clip
        var destination: Rect
        #if canImport(VideoToolbox) && canImport(CoreMedia)
        var decoder: VideoDecoder?
        #endif
    }

    private let connection: ChannelConnection
    private let events: AsyncStream<DisplayEvent>.Continuation
    private let log = ChannelLogger(category: "display")

    private var surfaces: [UInt32: SurfaceState] = [:]
    private var surfacePixels = 0
    /// Messages that couldn't be decoded (diagnostics and tests).
    public private(set) var decodeErrorCount = 0
    /// Stops the flush retry loop once the channel is gone.
    private var closed = false
    private var primaryID: UInt32?
    private var dirty: Rect?
    private var flushScheduled = false
    private var resolver = ImageResolver(pixmapCacheBudget: DisplayChannel.pixmapCacheBudget)
    private var streams: [UInt32: VideoStream] = [:]
    private var warnedTypes: Set<UInt16> = []

    /// Hard limits for hostile servers.
    static let maxSurfaceDimension: UInt32 = 16_384
    static let maxSurfaces = 1024
    /// Aggregate pixel budget for all surfaces (512 MiB at 4 bytes/pixel: three 8K screens).
    static let maxSurfacePixels = 128 * 1024 * 1024
    static let maxStreams = 64

    private let credit: DisplayUpdateCredit?
    private let clock: MultimediaClock?
    /// Stream reports waiting to be sent (built while handling STREAM_DATA).
    private var pendingReports: [StreamReport] = []

    /// `credit` enables backpressure; `nil` (tests) publishes every flush. `clock` (the
    /// server multimedia time) enables stream reports.
    public init(connection: ChannelConnection, events: AsyncStream<DisplayEvent>.Continuation,
                credit: DisplayUpdateCredit? = nil, clock: MultimediaClock? = nil) {
        self.connection = connection
        self.events = events
        self.credit = credit
        self.clock = clock
    }

    /// Sends `DISPLAY_INIT` and preferences, then processes messages until closed.
    public func run() async throws {
        defer {
            closed = true
            events.finish()
        }
        try await connection.send(DisplayClientEncoder.initialize(
            pixmapCacheID: 1, pixmapCacheSize: Int64(Self.pixmapCacheBudget),
            glzDictionaryID: 1, glzWindowSize: Self.glzWindowSize
        ))
        if connection.serverCaps.contains(DisplayCapability.prefCompression.rawValue) {
            // GLZ (global dictionary) compresses best over WAN; QUIC is used for photos.
            try await connection.send(DisplayClientEncoder.preferredCompression(.autoGLZ))
        }
        if connection.serverCaps.contains(DisplayCapability.prefVideoCodecType.rawValue) {
            // Ask for hardware-decodable video first; the server falls back to what it can encode.
            try await connection.send(DisplayClientEncoder.preferredVideoCodecs(Self.videoCodecs))
        }
        while true {
            let message = try await connection.nextMessage()
            do {
                try handle(message)
            } catch WireError.limitExceeded(let what) {
                // Resource budgets are hard limits: a server exceeding them is dropped.
                log.error("display budget exceeded (\(what)); closing the session")
                throw WireError.limitExceeded(what)
            } catch let error as WireError {
                decodeErrorCount += 1
                log.error("malformed display message \(message.type): \(error)")
            } catch let error as ImageResolveError {
                decodeErrorCount += 1
                log.error("image error in message \(message.type): \(error)")
            }
            scheduleFlush()
            for report in pendingReports {
                try await connection.send(DisplayClientEncoder.streamReport(report))
            }
            pendingReports.removeAll()
        }
    }

    public func close() async {
        closed = true
        await connection.close()
    }

    // MARK: Dispatch

    private func handle(_ message: SpiceMessage) throws {
        guard let type = DisplayServerMessage(rawValue: message.type) else {
            warnOnce(message.type, "unknown display message")
            return
        }
        let payload = message.payload
        switch type {
        case .surfaceCreate:
            try createSurface(SurfaceCreate(decoding: payload))
        case .surfaceDestroy:
            destroySurface(try SurfaceDestroy(decoding: payload).surfaceID)
        case .drawFill:
            let draw = try DrawFill(decoding: payload)
            let source: FillSource
            switch draw.brush {
            case .none: return
            case .solid(let color): source = .color(color)
            case .pattern(let image, let position):
                guard let image else { return }
                source = .pattern(try resolve(image), origin: position)
            }
            let mask = resolver.mask(for: draw.mask)
            mutate(draw.base) { $0.fill(box: draw.base.box, clip: draw.base.clip, source: source, rop: draw.rop, mask: mask) }
        case .drawCopy, .drawBlend:
            let draw = try DrawCopy(decoding: payload)
            guard let image = draw.source else { return }
            let source = try resolve(image)
            let mask = resolver.mask(for: draw.mask)
            mutate(draw.base) {
                $0.copy(from: source, sourceArea: draw.sourceArea, box: draw.base.box, clip: draw.base.clip,
                        rop: draw.rop, scaleMode: draw.scaleMode, mask: mask)
            }
        case .drawOpaque:
            let draw = try DrawOpaque(decoding: payload)
            guard let image = draw.source else { return }
            let source = try resolve(image)
            let mask = resolver.mask(for: draw.mask)
            mutate(draw.base) {
                $0.copy(from: source, sourceArea: draw.sourceArea, box: draw.base.box, clip: draw.base.clip,
                        rop: draw.rop, scaleMode: draw.scaleMode, mask: mask)
            }
        case .drawBlackness, .drawWhiteness, .drawInvers:
            let draw = try DrawMaskOnly(decoding: payload)
            let rop: Ropd = type == .drawBlackness ? .opBlackness : type == .drawWhiteness ? .opWhiteness : .opInvers
            let mask = resolver.mask(for: draw.mask)
            mutate(draw.base) { $0.applyUnary(box: draw.base.box, clip: draw.base.clip, rop: rop, mask: mask) }
        case .drawTransparent:
            let draw = try DrawTransparent(decoding: payload)
            guard let image = draw.source else { return }
            let source = try resolve(image)
            mutate(draw.base) {
                $0.transparentCopy(from: source, sourceArea: draw.sourceArea, box: draw.base.box,
                                   clip: draw.base.clip, colorKey: draw.sourceColor)
            }
        case .drawAlphaBlend:
            let draw = try DrawAlphaBlend(decoding: payload)
            guard let image = draw.source else { return }
            let source = try resolve(image)
            let hasAlpha = draw.sourceHasAlpha || source.hasAlpha
            mutate(draw.base) {
                $0.alphaBlend(from: source, sourceArea: draw.sourceArea, box: draw.base.box, clip: draw.base.clip,
                              alpha: draw.alpha, sourceHasAlpha: hasAlpha)
            }
        case .copyBits:
            let draw = try CopyBits(decoding: payload)
            mutate(draw.base) { $0.copyBits(sourcePosition: draw.sourcePosition, box: draw.base.box, clip: draw.base.clip) }
        case .invalList:
            for resource in try InvalidateList(decoding: payload).resources { resolver.invalidatePixmap(resource.id) }
        case .invalAllPixmaps:
            resolver.invalidateAllPixmaps()
        case .invalPalette:
            resolver.invalidatePalette(try InvalidateOne(decoding: payload).id)
        case .invalAllPalettes:
            resolver.invalidateAllPalettes()
        case .monitorsConfig:
            events.yield(.monitorsConfig(try MonitorsConfig(decoding: payload).heads))
        case .streamCreate:
            let create = try StreamCreate(decoding: payload)
            guard streams.count < Self.maxStreams || streams[create.streamID] != nil else {
                throw WireError.limitExceeded("too many video streams")
            }
            var stream = VideoStream(create: create, clip: create.clip, destination: create.destination)
            switch create.codec {
            case .mjpeg:
                break
            #if canImport(VideoToolbox) && canImport(CoreMedia)
            case .h264:
                stream.decoder = VideoDecoder(codec: .h264)
            case .h265:
                stream.decoder = VideoDecoder(codec: .h265)
            #endif
            default:
                warnOnce(message.type, "unsupported stream codec \(create.rawCodec)")
            }
            streams[create.streamID] = stream
        case .streamData, .streamDataSized:
            try handleStreamData(StreamData(decoding: payload, sized: type == .streamDataSized))
        case .streamClip:
            let clip = try StreamClip(decoding: payload)
            streams[clip.streamID]?.clip = clip.clip
        case .streamDestroy:
            streams.removeValue(forKey: try StreamDestroy(decoding: payload).streamID)
        case .streamDestroyAll:
            streams.removeAll()
        case .reset:
            resolver.invalidateAllPixmaps()
            resolver.invalidateAllPalettes()
            streams.removeAll()
        case .mark, .mode:
            break
        case .streamActivateReport:
            let activate = try StreamActivateReport(decoding: payload)
            guard clock != nil, streams[activate.streamID] != nil else { break }
            streams[activate.streamID]?.report = ReportWindow(
                uniqueID: activate.uniqueID, maxFrames: max(1, activate.maxWindowSize),
                timeout: .milliseconds(Int(min(activate.timeoutMS, 60_000))))
        case .qualityIndicator, .glScanoutUnix, .glDraw:
            break  // not advertised
        case .drawRop3, .drawStroke, .drawText, .drawComposite:
            warnOnce(message.type, "unsupported draw command")
        }
    }

    // MARK: Surfaces

    private func createSurface(_ create: SurfaceCreate) throws {
        guard create.width > 0, create.height > 0,
              create.width <= Self.maxSurfaceDimension, create.height <= Self.maxSurfaceDimension else {
            throw WireError.limitExceeded("surface \(create.width)x\(create.height)")
        }
        guard surfaces.count < Self.maxSurfaces || surfaces[create.surfaceID] != nil else {
            throw WireError.limitExceeded("too many surfaces")
        }
        // Reserve against the aggregate budget before allocating (a replaced surface is freed).
        let replaced = surfaces[create.surfaceID].map { $0.buffer.width * $0.buffer.height } ?? 0
        let requested = Int(create.width) * Int(create.height)
        guard surfacePixels - replaced + requested <= Self.maxSurfacePixels else {
            throw WireError.limitExceeded("surface memory budget")
        }
        surfacePixels += requested - replaced
        let format = create.format
        let hasAlpha = format == .argb32 || format == .a8 || format == .a1
        let buffer = PixelBuffer(width: Int(create.width), height: Int(create.height),
                                 fill: hasAlpha ? 0 : 0xFF00_0000, hasAlpha: hasAlpha)
        surfaces[create.surfaceID] = SurfaceState(buffer: buffer, format: format, isPrimary: create.isPrimary)
        if create.isPrimary {
            primaryID = create.surfaceID
            dirty = nil
            events.yield(.primarySurfaceCreated(surfaceID: create.surfaceID, width: Int(create.width), height: Int(create.height)))
            markDirty(buffer.bounds)
        }
    }

    private func destroySurface(_ id: UInt32) {
        guard let removed = surfaces.removeValue(forKey: id) else { return }
        surfacePixels -= removed.buffer.width * removed.buffer.height
        if id == primaryID {
            primaryID = nil
            dirty = nil
            events.yield(.primarySurfaceDestroyed(surfaceID: id))
        }
    }

    private func resolve(_ image: Image) throws -> PixelBuffer {
        let snapshot = surfaces
        return try resolver.resolve(image) { snapshot[$0]?.buffer }
    }

    /// Applies a drawing operation to the target surface and records the dirty area.
    private func mutate(_ base: DisplayBase, _ body: (inout PixelBuffer) -> Rect) {
        guard var state = surfaces[base.surfaceID] else {
            log.debug("draw to unknown surface \(base.surfaceID)")
            return
        }
        surfaces[base.surfaceID] = nil  // keep the buffer uniquely referenced while mutating
        let changed = body(&state.buffer)
        surfaces[base.surfaceID] = state
        if base.surfaceID == primaryID, !changed.isEmpty { markDirty(changed) }
    }

    // MARK: Video streams

    private func recordFrame(streamID: UInt32, frameTime: UInt32, dropped: Bool) {
        guard var report = streams[streamID]?.report, let now = clock?.now else { return }
        if report.started == nil {
            report.started = .now
            report.startFrameTime = frameTime
        }
        report.frames += 1
        if dropped { report.drops += 1 }
        report.endFrameTime = frameTime
        report.lastDelay = Int32(truncatingIfNeeded: Int64(frameTime) - Int64(now))
        if report.frames >= report.maxFrames || ContinuousClock.now - (report.started ?? .now) >= report.timeout {
            pendingReports.append(StreamReport(
                streamID: streamID, uniqueID: report.uniqueID, startFrameMMTime: report.startFrameTime,
                endFrameMMTime: report.endFrameTime, frames: report.frames, drops: report.drops,
                lastFrameDelay: report.lastDelay))
            report = ReportWindow(uniqueID: report.uniqueID, maxFrames: report.maxFrames, timeout: report.timeout)
        }
        streams[streamID]?.report = report
    }

    private func handleStreamData(_ data: StreamData) throws {
        guard var stream = streams[data.streamID] else { return }
        if let resize = data.resize { stream.destination = resize.destination }
        streams[data.streamID] = stream
        var decoded: PixelBuffer?
        switch stream.create.codec {
        case .mjpeg:
            #if canImport(ImageIO)
            decoded = try? JPEGDecoder.decode(data.data)
            #endif
            break  // keeps the case non-empty where ImageIO is unavailable
        case .h264, .h265:
            #if canImport(VideoToolbox) && canImport(CoreMedia)
            do {
                decoded = try stream.decoder?.decode(data.data)
            } catch {
                log.debug("video frame decode failed: \(error)")
            }
            #endif
            break  // keeps the case non-empty where VideoToolbox is unavailable
        default:
            break
        }
        recordFrame(streamID: data.streamID, frameTime: data.multimediaTime, dropped: decoded == nil)
        guard var frame = decoded else { return }
        if !stream.create.isTopDown { frame.flipVertically() }
        let base = DisplayBase(surfaceID: stream.create.surfaceID, box: stream.destination, clip: stream.clip)
        mutate(base) {
            $0.copy(from: frame, sourceArea: frame.bounds, box: stream.destination, clip: stream.clip,
                    rop: .opPut, scaleMode: .interpolate)
        }
    }

    // MARK: Flushing

    private func markDirty(_ rect: Rect) {
        dirty = (dirty ?? rect).union(rect)
    }

    private func scheduleFlush() {
        guard dirty != nil, !flushScheduled else { return }
        flushScheduled = true
        Task { self.flush() }
    }

    /// Publishes the accumulated dirty region of the primary surface.
    public func flush() {
        flushScheduled = false
        guard !closed, let rect = dirty, let id = primaryID, let surface = surfaces[id] else { return }
        let clipped = rect.intersection(surface.buffer.bounds)
        guard !clipped.isEmpty else {
            dirty = nil
            return
        }
        if let credit, !credit.tryAcquire() {
            // Renderer is behind: keep accumulating damage and look again shortly.
            flushScheduled = true
            Task {
                try? await Task.sleep(for: .milliseconds(4))
                self.flush()
            }
            return
        }
        dirty = nil
        let region = surface.buffer.cropped(x: Int(clipped.left), y: Int(clipped.top),
                                            width: clipped.width, height: clipped.height)
        events.yield(.update(SurfaceUpdate(surfaceID: id, rect: clipped, pixels: region.pixels)))
    }

    /// Current primary surface pixels (for snapshots and tests).
    public func primarySurface() -> PixelBuffer? {
        primaryID.flatMap { surfaces[$0]?.buffer }
    }

    private func warnOnce(_ type: UInt16, _ text: String) {
        if warnedTypes.insert(type).inserted { log.info("\(text) (type \(type))") }
    }
}

/// A display event of an additional monitor (display channel id ≥ 1).
public struct SecondaryDisplayEvent: Sendable {
    public var display: UInt8
    public var event: DisplayEvent

    public init(display: UInt8, event: DisplayEvent) {
        self.display = display
        self.event = event
    }
}
