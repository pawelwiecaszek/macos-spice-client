/// A 32-bit image in premultiplied BGRA8 byte order.
///
/// Each pixel is a `UInt32` holding `0xAARRGGBB`; stored little-endian that is the byte
/// sequence B, G, R, A — exactly Metal's `.bgra8Unorm`. Rows are top-down with no padding.
public struct PixelBuffer: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt32]
    /// `false` when the source had no alpha channel (alpha is then forced to 0xFF).
    public var hasAlpha: Bool

    public init(width: Int, height: Int, fill: UInt32 = 0xFF00_0000, hasAlpha: Bool = false) {
        precondition(width >= 0 && height >= 0)
        self.width = width
        self.height = height
        self.pixels = Array(repeating: fill, count: width * height)
        self.hasAlpha = hasAlpha
    }

    public init(width: Int, height: Int, pixels: [UInt32], hasAlpha: Bool) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
        self.hasAlpha = hasAlpha
    }

    @inline(__always)
    public subscript(x: Int, y: Int) -> UInt32 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Reverses the row order in place (bottom-up → top-down).
    public mutating func flipVertically() {
        guard height > 1 else { return }
        let w = width
        pixels.withUnsafeMutableBufferPointer { buffer in
            var top = 0
            var bottom = height - 1
            while top < bottom {
                for x in 0..<w {
                    buffer.swapAt(top * w + x, bottom * w + x)
                }
                top += 1
                bottom -= 1
            }
        }
    }

    /// Copies out a sub-rectangle (clamped to the buffer).
    public func cropped(x: Int, y: Int, width w: Int, height h: Int) -> PixelBuffer {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        guard x1 > x0, y1 > y0 else { return PixelBuffer(width: 0, height: 0) }
        var out = [UInt32]()
        out.reserveCapacity((x1 - x0) * (y1 - y0))
        for row in y0..<y1 {
            out.append(contentsOf: pixels[(row * width + x0)..<(row * width + x1)])
        }
        return PixelBuffer(width: x1 - x0, height: y1 - y0, pixels: out, hasAlpha: hasAlpha)
    }
}

/// Errors from image decoders. Server data is untrusted; every failure is recoverable.
public enum CodecError: Error, Equatable, Sendable {
    case badMagic
    case unsupportedVersion(UInt32)
    case unsupportedType(String)
    case truncated
    case corrupt(String)
    case missingPalette
    case tooLarge(width: Int, height: Int)
}

/// Safety limits for decoded images.
public enum CodecLimits {
    public static let maxDimension = 16_384
    public static let maxPixels = 64 * 1024 * 1024

    static func check(width: Int, height: Int) throws(CodecError) {
        guard width > 0, height > 0, width <= maxDimension, height <= maxDimension,
              width * height <= maxPixels else {
            throw .tooLarge(width: width, height: height)
        }
    }
}

@inline(__always)
func opaque(r: UInt32, g: UInt32, b: UInt32) -> UInt32 {
    0xFF00_0000 | (r & 0xFF) << 16 | (g & 0xFF) << 8 | (b & 0xFF)
}

/// Expands a 5-bit channel to 8 bits.
@inline(__always)
func expand5(_ value: UInt32) -> UInt32 {
    (value << 3) | (value >> 2)
}

/// x555 (`0RRRRRGG GGGBBBBB`) → opaque BGRA.
@inline(__always)
func pixelFrom555(_ value: UInt16) -> UInt32 {
    let v = UInt32(value)
    return opaque(r: expand5((v >> 10) & 0x1F), g: expand5((v >> 5) & 0x1F), b: expand5(v & 0x1F))
}
