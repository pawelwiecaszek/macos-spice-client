import SpiceWire

/// Events from the playback channel (guest → speakers).
public enum PlaybackEvent: Sendable, Equatable {
    case start(channels: Int, frequency: Int)
    case stop
    /// One packet: raw S16LE interleaved PCM, or one Opus frame.
    case data(mode: AudioDataMode, time: UInt32, bytes: [UInt8])
    case volume(Float)
    case mute(Bool)
    case latency(milliseconds: UInt32)
}

/// Playback channel: forwards audio packets; decoding and output live in the host layer.
public actor PlaybackChannel {
    public static func capabilities(opus: Bool) -> CapabilitySet {
        var bits = [PlaybackCapability.volume.rawValue, PlaybackCapability.latency.rawValue]
        if opus { bits.append(PlaybackCapability.opus.rawValue) }
        return CapabilitySet(bits: bits)
    }

    /// Largest packet accepted (10 ms of 8-channel 192 kHz PCM is ~31 KB).
    static let maxPacket = 64 * 1024

    private let connection: ChannelConnection
    private let events: AsyncStream<PlaybackEvent>.Continuation
    private var mode: AudioDataMode = .raw
    private let log = ChannelLogger(category: "playback")

    public init(connection: ChannelConnection, events: AsyncStream<PlaybackEvent>.Continuation) {
        self.connection = connection
        self.events = events
    }

    public func run() async throws {
        defer { events.yield(.stop) }
        while true {
            let message = try await connection.nextMessage()
            guard message.payload.count <= Self.maxPacket else {
                log.error("dropping oversized audio packet (\(message.payload.count) bytes)")
                continue
            }
            do {
                switch PlaybackServerMessage(rawValue: message.type) {
                case .mode:
                    let packet = try AudioPacket(decodingMode: message.payload)
                    mode = packet.mode ?? .invalid
                    if !packet.data.isEmpty { events.yield(.data(mode: mode, time: packet.time, bytes: packet.data)) }
                case .data:
                    let packet = try AudioPacket(decodingData: message.payload)
                    events.yield(.data(mode: mode, time: packet.time, bytes: packet.data))
                case .start:
                    let start = try AudioStart(decoding: message.payload, hasTime: true)
                    guard start.format == audioFormatS16 else {
                        log.error("unsupported audio format \(start.format)")
                        continue
                    }
                    events.yield(.start(channels: Int(start.channels), frequency: Int(start.frequency)))
                case .stop:
                    events.yield(.stop)
                case .volume:
                    events.yield(.volume(try AudioVolume(decoding: message.payload).normalized))
                case .mute:
                    events.yield(.mute(message.payload.first.map { $0 != 0 } ?? false))
                case .latency:
                    var reader = ByteReader(message.payload)
                    events.yield(.latency(milliseconds: try reader.readU32()))
                case nil:
                    continue
                }
            } catch {
                log.error("malformed playback message \(message.type): \(error)")
            }
        }
    }

    public func close() async {
        await connection.close()
    }
}

/// Events from the record channel (microphone → guest).
public enum RecordEvent: Sendable, Equatable {
    case start(channels: Int, frequency: Int)
    case stop
    case volume(Float)
    case mute(Bool)
}

/// Record channel: the guest asks for audio with START; the client answers with MODE,
/// START_MARK and then DATA packets until STOP.
public actor RecordChannel {
    public static func capabilities(opus: Bool) -> CapabilitySet {
        var bits = [RecordCapability.volume.rawValue]
        if opus { bits.append(RecordCapability.opus.rawValue) }
        return CapabilitySet(bits: bits)
    }

    private let connection: ChannelConnection
    private let events: AsyncStream<RecordEvent>.Continuation
    private var active = false
    private var markSent = false
    private var sentMode: AudioDataMode?
    private let log = ChannelLogger(category: "record")

    public init(connection: ChannelConnection, events: AsyncStream<RecordEvent>.Continuation) {
        self.connection = connection
        self.events = events
    }

    /// `true` while the guest is recording.
    public var isActive: Bool { active }

    public func run() async throws {
        defer {
            active = false
            events.yield(.stop)
        }
        while true {
            let message = try await connection.nextMessage()
            do {
                switch RecordServerMessage(rawValue: message.type) {
                case .start:
                    let start = try AudioStart(decoding: message.payload, hasTime: false)
                    guard start.format == audioFormatS16 else { continue }
                    active = true
                    markSent = false
                    sentMode = nil
                    events.yield(.start(channels: Int(start.channels), frequency: Int(start.frequency)))
                case .stop:
                    active = false
                    events.yield(.stop)
                case .volume:
                    events.yield(.volume(try AudioVolume(decoding: message.payload).normalized))
                case .mute:
                    events.yield(.mute(message.payload.first.map { $0 != 0 } ?? false))
                case nil:
                    continue
                }
            } catch {
                log.error("malformed record message \(message.type): \(error)")
            }
        }
    }

    /// Sends captured audio (ignored unless the guest is recording).
    public func send(_ bytes: [UInt8], mode: AudioDataMode, time: UInt32) async {
        guard active, !bytes.isEmpty, bytes.count <= 64 * 1024 else { return }
        do {
            if sentMode != mode {
                try await connection.send(RecordClientEncoder.mode(mode, time: time))
                sentMode = mode
            }
            if !markSent {
                try await connection.send(RecordClientEncoder.startMark(time: time))
                markSent = true
            }
            try await connection.send(RecordClientEncoder.data(bytes, time: time))
        } catch {
            log.debug("record send failed: \(error)")
        }
    }

    public func close() async {
        await connection.close()
    }
}
