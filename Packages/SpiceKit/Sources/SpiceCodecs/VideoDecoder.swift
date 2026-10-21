#if canImport(VideoToolbox) && canImport(CoreMedia)
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 / H.265 decoding of SPICE video stream frames with VideoToolbox.
///
/// Each `decode` call takes one access unit in Annex B form (parameter sets included in
/// key frames, as spice-server's GStreamer encoders emit them) and returns the frame as
/// BGRA pixels. The session is (re)created whenever the parameter sets change.
/// Not thread-safe: owned by one display channel actor.
public final class VideoDecoder {
    public enum Codec: Sendable {
        case h264, h265
    }

    public let codec: Codec
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [[UInt8]] = []

    public init(codec: Codec) {
        self.codec = codec
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Whether this Mac decodes `codec` in hardware.
    public static func hardwareSupported(_ codec: Codec) -> Bool {
        VTIsHardwareDecodeSupported(codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC)
    }

    /// Decodes one access unit. Returns `nil` while waiting for the first key frame.
    public func decode(_ accessUnit: ArraySlice<UInt8>) throws(CodecError) -> PixelBuffer? {
        let hevc = codec == .h265
        let units = AnnexB.nalUnits(accessUnit)
        let sets = units.filter { AnnexB.isParameterSet(AnnexB.nalType($0, hevc: hevc), hevc: hevc) }.map(Array.init)
        if !sets.isEmpty, sets != parameterSets {
            try configure(parameterSets: sets)
        }
        guard let session, let format else { return nil }
        let picture = units.filter {
            let type = AnnexB.nalType($0, hevc: hevc)
            // Drop parameter sets (in the format description) and access unit delimiters.
            return !AnnexB.isParameterSet(type, hevc: hevc) && type != (hevc ? 35 : 9)
        }
        guard !picture.isEmpty else { return nil }
        let sample = try makeSampleBuffer(AnnexB.lengthPrefixed(picture), format: format)

        let output = DecodeOutput()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            output.store(status: status, image: imageBuffer)
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard status == noErr else {
            // Bad frame or lost reference: start over at the next key frame.
            reset()
            throw .corrupt("video decode \(status)")
        }
        guard let image = output.image else { return nil }  // frame dropped by the decoder
        return try Self.pixels(from: image)
    }

    private func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        parameterSets = []
    }

    private func configure(parameterSets sets: [[UInt8]]) throws(CodecError) {
        reset()
        var newFormat: CMFormatDescription?
        let status: OSStatus = withPointers(sets) { pointers, sizes in
            if codec == .h265 {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &newFormat)
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
        }
        guard status == noErr, let newFormat else { throw .corrupt("video parameter sets \(status)") }
        let dimensions = CMVideoFormatDescriptionGetDimensions(newFormat)
        try CodecLimits.check(width: Int(dimensions.width), height: Int(dimensions.height))

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        ]
        let specification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        var newSession: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: newFormat, decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &newSession)
        guard created == noErr, let newSession else { throw .corrupt("video session \(created)") }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
        format = newFormat
        parameterSets = sets
    }

    private func withPointers<R>(_ sets: [[UInt8]],
                                 _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        // Copy into one contiguous allocation that outlives the call.
        let total = sets.reduce(0) { $0 + $1.count }
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: max(total, 1))
        defer { storage.deallocate() }
        var pointers: [UnsafePointer<UInt8>] = []
        var offset = 0
        for set in sets {
            set.withUnsafeBufferPointer { (storage + offset).update(from: $0.baseAddress!, count: set.count) }
            pointers.append(UnsafePointer(storage + offset))
            offset += set.count
        }
        let sizes = sets.map(\.count)
        return pointers.withUnsafeBufferPointer { p in
            sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) }
        }
    }

    private func makeSampleBuffer(_ bytes: [UInt8], format: CMFormatDescription) throws(CodecError) -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw .corrupt("video block \(status)") }
        status = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == noErr else { throw .corrupt("video block copy \(status)") }
        var sample: CMSampleBuffer?
        var size = bytes.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw .corrupt("video sample \(status)") }
        return sample
    }

    static func pixels(from image: CVImageBuffer) throws(CodecError) -> PixelBuffer {
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        try CodecLimits.check(width: width, height: height)
        guard CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { throw .corrupt("video lock") }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { throw .corrupt("video base") }
        let stride = CVPixelBufferGetBytesPerRow(image)
        var output = PixelBuffer(width: width, height: height)
        output.pixels.withUnsafeMutableBytes { destination in
            for row in 0..<height {
                // BGRA in memory == 0xAARRGGBB little-endian, our pixel format; force opaque.
                let source = base.advanced(by: row * stride).assumingMemoryBound(to: UInt32.self)
                let target = destination.baseAddress!.advanced(by: row * width * 4).assumingMemoryBound(to: UInt32.self)
                for x in 0..<width { target[x] = source[x] | 0xFF00_0000 }
            }
        }
        return output
    }
}

/// Receives the decoder callback (which may run on a VideoToolbox thread).
private final class DecodeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var _image: CVImageBuffer?

    var image: CVImageBuffer? { lock.withLock { _image } }

    func store(status: OSStatus, image: CVImageBuffer?) {
        lock.withLock { _image = status == noErr ? image : nil }
    }
}
#endif
