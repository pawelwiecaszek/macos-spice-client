import Testing
@testable import SpiceCodecs

@Suite("Annex B")
struct AnnexBTests {
    @Test func splitsOnThreeAndFourByteStartCodes() {
        let stream: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5, 0]
        let units = AnnexB.nalUnits(stream[...])
        #expect(units.map(Array.init) == [[0x67, 1, 2], [0x68, 3], [0x65, 4, 5]])
        #expect(units.map { AnnexB.nalType($0, hevc: false) } == [7, 8, 5])
        #expect(AnnexB.isParameterSet(7, hevc: false) && !AnnexB.isParameterSet(5, hevc: false))
        #expect(AnnexB.lengthPrefixed(units) == [0, 0, 0, 3, 0x67, 1, 2, 0, 0, 0, 2, 0x68, 3, 0, 0, 0, 3, 0x65, 4, 5])
    }

    @Test func hevcTypesAndGarbage() {
        // HEVC VPS (32) → first byte 0x40.
        #expect(AnnexB.nalType([0x40, 0x01][...], hevc: true) == 32)
        #expect(AnnexB.isParameterSet(33, hevc: true))
        #expect(AnnexB.nalUnits([1, 2, 3][...]).isEmpty)
        #expect(AnnexB.nalUnits([][...]).isEmpty)
    }
}

#if canImport(VideoToolbox) && canImport(CoreMedia)
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Encodes frames with VideoToolbox, then decodes them through `VideoDecoder` the way
/// they arrive from spice-server (Annex B, parameter sets in the key frame).
@Suite("VideoToolbox decoder")
struct VideoDecoderTests {
    final class Collector: @unchecked Sendable {
        var samples: [CMSampleBuffer] = []
        let lock = NSLock()
    }

    static func encode(codec: CMVideoCodecType, width: Int, height: Int, frames: Int) throws -> [[UInt8]] {
        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: codec,
                                         encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr,
              let session else { throw CodecError.corrupt("encoder unavailable") }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        let collector = Collector()
        for index in 0..<frames {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            guard let pixelBuffer else { throw CodecError.corrupt("pixel buffer") }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 0..<height {
                for x in 0..<width {
                    let p = base + y * stride + x * 4
                    // Left half red, right half blue (BGRA).
                    p[0] = x < width / 2 ? 0 : 255; p[1] = 0; p[2] = x < width / 2 ? 255 : 0; p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let time = CMTime(value: CMTimeValue(index), timescale: 30)
            VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: time,
                                            duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
                guard status == noErr, let sample else { return }
                collector.lock.withLock { collector.samples.append(sample) }
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return try collector.samples.map { try annexB($0, hevc: codec == kCMVideoCodecType_HEVC) }
    }

    /// AVCC sample → Annex B access unit, prepending the parameter sets like a byte-stream encoder.
    static func annexB(_ sample: CMSampleBuffer, hevc: Bool) throws -> [UInt8] {
        var out: [UInt8] = []
        let format = CMSampleBufferGetFormatDescription(sample)!
        var count = 0
        if hevc {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            if hevc {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            } else {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            out += [0, 0, 0, 1] + Array(UnsafeBufferPointer(start: pointer, count: size))
        }
        let block = CMSampleBufferGetDataBuffer(sample)!
        var length = 0
        var data: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &data)
        let bytes = UnsafeRawBufferPointer(start: data, count: length).map { $0 }
        var offset = 0
        while offset + 4 <= bytes.count {
            let n = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            out += [0, 0, 0, 1] + bytes[(offset + 4)..<(offset + 4 + n)]
            offset += 4 + n
        }
        return out
    }

    @Test(arguments: [VideoDecoder.Codec.h264, .h265])
    func roundTrip(codec: VideoDecoder.Codec) throws {
        let type = codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        let units = try Self.encode(codec: type, width: 320, height: 240, frames: 5)
        try #require(!units.isEmpty)
        let decoder = VideoDecoder(codec: codec)
        var decodedFrames = 0
        for unit in units {
            guard let frame = try decoder.decode(unit[...]) else { continue }
            decodedFrames += 1
            #expect(frame.width == 320 && frame.height == 240)
            let left = frame[40, 120], right = frame[280, 120]
            #expect((left >> 16) & 0xFF > 200 && left & 0xFF < 60)  // red
            #expect(right & 0xFF > 200 && (right >> 16) & 0xFF < 60)  // blue
        }
        #expect(decodedFrames >= units.count - 1)
    }

    @Test func waitsForKeyFrameAndSurvivesGarbage() throws {
        let decoder = VideoDecoder(codec: .h264)
        #expect(try decoder.decode([0, 0, 1, 0x41, 1, 2, 3][...]) == nil)  // P-slice before any SPS
        // Corrupt parameter sets / slices must fail cleanly (error or no frame), never crash.
        _ = try? decoder.decode([0, 0, 1, 0x67, 0xFF, 0, 0, 1, 0x68, 0xFF, 0, 0, 1, 0x65, 1, 2][...])
    }
}
#endif
