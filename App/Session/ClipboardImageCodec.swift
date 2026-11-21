import Foundation
import ImageIO

/// ImageIO work runs on a utility task, never on the pasteboard's main actor.
enum ClipboardImageCodec {
    static let maximumPixels = 64 * 1024 * 1024
    static let maximumBytes = 32 * 1024 * 1024

    static func acceptsDimensions(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maximumPixels && height <= maximumPixels
            && width <= maximumPixels / height
    }

    static func encodePNG(_ data: Data, requirePNG: Bool) -> Data? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              !requirePNG || CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              acceptsDimensions(width: width, height: height),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maximumBytes else { return nil }
        return output as Data
    }
}
