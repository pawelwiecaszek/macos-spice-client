#if canImport(AVFoundation)
import AVFoundation

/// Captures the Mac's default microphone and delivers fixed-size packets in the format
/// the guest asked for: interleaved S16LE PCM (10 ms per packet) or Opus frames.
///
/// Needs the `com.apple.security.device.audio-input` entitlement and the user's
/// microphone permission. Only runs while explicitly started.
public final class MicrophoneCapture: @unchecked Sendable {
    public enum Output: Sendable {
        case raw([UInt8])
        case opus([UInt8])
    }

    // Engine objects are owned by the caller's actor; the tap runs serially on one audio
    // thread and only touches its own `CaptureState`.
    private let engine = AVAudioEngine()
    private var running = false

    public init() {}

    /// Asks for microphone access if needed.
    public static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Starts capturing; `deliver` is called on the audio thread with each packet.
    public func start(channels: Int, sampleRate: Int, useOpus: Bool,
                      deliver: @escaping @Sendable (Output) -> Void) throws {
        stop()
        let channels = max(1, min(channels, 2))
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate),
                                         channels: AVAudioChannelCount(channels), interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw CaptureError.noInput
        }
        let encoder = useOpus && sampleRate == Int(OpusCodec.sampleRate) ? OpusEncoder(channels: channels) : nil
        let packetFrames = encoder?.frameSize ?? sampleRate / 100
        let state = CaptureState(converter: converter, target: target, encoder: encoder)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            guard let samples = state.convert(buffer) else { return }
            var packets: [[Int16]] = []
            state.pending += samples
            let size = packetFrames * channels
            while state.pending.count >= size {
                packets.append(Array(state.pending.prefix(size)))
                state.pending.removeFirst(size)
            }
            if state.pending.count > size * 50 { state.pending.removeAll() }  // never grow without bound
            for packet in packets {
                if let encoder = state.encoder {
                    if let frame = encoder.encode(packet) { deliver(.opus(frame)) }
                } else {
                    deliver(.raw(packet.withUnsafeBytes { Array($0) }))
                }
            }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    public var isRunning: Bool { running }

    public enum CaptureError: Error {
        case noInput
    }
}

/// Converter state used only on the tap's audio thread.
private final class CaptureState: @unchecked Sendable {
    let converter: AVAudioConverter
    let target: AVAudioFormat
    let encoder: OpusEncoder?
    var pending: [Int16] = []

    init(converter: AVAudioConverter, target: AVAudioFormat, encoder: OpusEncoder?) {
        self.converter = converter
        self.target = target
        self.encoder = encoder
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Int16]? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let feed = OneShotInput(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in feed.next(outStatus) }
        guard status != .error, error == nil, let data = output.int16ChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength) * Int(target.channelCount)))
    }
}
#endif
