import SpiceWire

/// Native surface-word conversion shared by Boolean raster operations.
enum RasterPixelFormat {
    @inline(__always)
    static func pack(_ pixel: UInt32, format: SurfaceFormat) -> UInt32 {
        switch format {
        case .x555: ((pixel >> 9) & 0x7C00) | ((pixel >> 6) & 0x03E0) | ((pixel >> 3) & 0x001F)
        case .r565: ((pixel >> 8) & 0xF800) | ((pixel >> 5) & 0x07E0) | ((pixel >> 3) & 0x001F)
        default: pixel
        }
    }

    @inline(__always)
    static func expand(_ pixel: UInt32, format: SurfaceFormat) -> UInt32 {
        switch format {
        case .x555: return pixelFrom555(UInt16(truncatingIfNeeded: pixel))
        case .r565:
            let green = (pixel >> 5) & 0x3F
            return opaque(r: expand5((pixel >> 11) & 0x1F), g: (green << 2) | (green >> 4), b: expand5(pixel & 0x1F))
        case .xRGB32: return pixel | 0xFF00_0000
        default: return pixel
        }
    }

}
