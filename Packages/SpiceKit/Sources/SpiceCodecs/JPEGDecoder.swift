#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import Foundation
import ImageIO

/// JPEG decoding via ImageIO (`SPICE_IMAGE_TYPE_JPEG`, `JPEG_ALPHA`, MJPEG stream frames).
public enum JPEGDecoder {
    public static func decode(_ data: ArraySlice<UInt8>) throws(CodecError) -> PixelBuffer {
        let cfData = Data(data) as CFData
        guard let source = CGImageSourceCreateWithData(cfData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw .corrupt("jpeg") }
        return try render(image)
    }

    /// `JPEG_ALPHA`: JPEG colour followed by an LZ (`XXXA`) alpha plane.
    public static func decodeWithAlpha(_ data: ArraySlice<UInt8>, jpegSize: Int, topDown: Bool) throws(CodecError) -> PixelBuffer {
        guard jpegSize <= data.count else { throw .truncated }
        let split = data.startIndex + jpegSize
        var color = try decode(data[data.startIndex..<split])
        let alpha = try LZDecoder.decode(data[split...])
        guard alpha.width == color.width, alpha.height == color.height else {
            throw .corrupt("jpeg alpha size mismatch")
        }
        _ = topDown  // LZ carries its own orientation; the flag only mirrors it.
        for i in color.pixels.indices {
            color.pixels[i] = (color.pixels[i] & 0x00FF_FFFF) | (alpha.pixels[i] & 0xFF00_0000)
        }
        color.hasAlpha = true
        return color
    }

    static func render(_ image: CGImage) throws(CodecError) -> PixelBuffer {
        let width = image.width, height = image.height
        try CodecLimits.check(width: width, height: height)
        var output = PixelBuffer(width: width, height: height)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let drawn: Bool = output.pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: info
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw .corrupt("jpeg render") }
        return output
    }
}
#endif
