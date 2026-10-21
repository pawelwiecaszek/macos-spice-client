#if canImport(AVFoundation)
import AVFoundation

/// Opus via AudioToolbox (`kAudioFormatOpus`). SPICE sends one Opus packet per message;
/// availability is probed at run time and only then advertised to the server.
public enum OpusCodec {
    public static let sampleRate: Double = 48_000

    public static var canDecode: Bool { OpusDecoder(channels: 2) != nil }
    public static var canEncode: Bool { OpusEncoder(channels: 2) != nil }

    static func opusFormat(channels: Int, framesPerPacket: UInt32) -> AVAudioFormat? {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &description)
    }

    static func pcmFormat(channels: Int) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: true)
    }
}

/// Decodes single Opus packets to interleaved S16 PCM.
public final class OpusDecoder {
    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    public let channels: Int

    public init?(channels: Int) {
        // 0 = variable frames per packet: AudioToolbox then decodes 10 ms (spice-server's
        // size) and 20 ms packets alike; a fixed size rejects the other one.
        guard let input = OpusCodec.opusFormat(channels: channels, framesPerPacket: 0),
              let output = OpusCodec.pcmFormat(channels: channels),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.input = input
        self.output = output
        self.converter = converter
        self.channels = channels
    }

    /// Interleaved S16 samples, or `nil` if the packet couldn't be decoded.
    public func decode(_ packet: [UInt8]) -> [Int16]? {
        guard !packet.isEmpty, packet.count <= 1500 else { return nil }
        let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        // Up to 120 ms per Opus packet.
        guard let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 5760) else { return nil }
        let feed = OneShotInput(compressed)
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, outStatus in feed.next(outStatus) }
        guard status != .error, error == nil, let samples = pcm.int16ChannelData else { return nil }
        let count = Int(pcm.frameLength) * channels
        return Array(UnsafeBufferPointer(start: samples[0], count: count))
    }
}

/// Encodes interleaved S16 PCM into Opus packets (frame size chosen by the encoder).
public final class OpusEncoder {
    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    public let channels: Int
    /// Samples per channel per packet.
    public let frameSize: Int

    public init?(channels: Int, bitRate: Int = 64_000) {
        guard let input = OpusCodec.pcmFormat(channels: channels),
              let output = OpusCodec.opusFormat(channels: channels, framesPerPacket: 960),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.bitRate = bitRate
        self.input = input
        self.output = output
        self.converter = converter
        self.channels = channels
        let frames = Int(output.streamDescription.pointee.mFramesPerPacket)
        frameSize = frames > 0 ? frames : 960
    }

    /// Encodes exactly `frameSize` frames (interleaved) into one packet.
    public func encode(_ samples: [Int16]) -> [UInt8]? {
        guard samples.count == frameSize * channels,
              let pcm = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(frameSize)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(frameSize)
        samples.withUnsafeBufferPointer { pcm.int16ChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let compressed = AVAudioCompressedBuffer(format: output, packetCapacity: 1,
                                                 maximumPacketSize: max(converter.maximumOutputPacketSize, 1500))
        let feed = OneShotInput(pcm)
        var error: NSError?
        let status = converter.convert(to: compressed, error: &error) { _, outStatus in feed.next(outStatus) }
        guard status != .error, error == nil, compressed.packetCount >= 1, compressed.byteLength > 0 else { return nil }
        let size = Int(compressed.packetDescriptions?.pointee.mDataByteSize ?? compressed.byteLength)
        return Array(UnsafeRawBufferPointer(start: compressed.data, count: size))
    }
}
/// Hands one buffer to an AVAudioConverter input block, then reports "no data now".
/// Only used synchronously within a single `convert` call.
final class OneShotInput: @unchecked Sendable {
    private var buffer: AVAudioBuffer?

    init(_ buffer: AVAudioBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
#endif
