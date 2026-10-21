import SpiceCodecs
import SpiceWire

/// Errors resolving an image reference.
public enum ImageResolveError: Error, Equatable, Sendable {
    case cacheMiss(UInt64)
    case paletteCacheMiss(UInt64)
    case unknownSurface(UInt32)
    case unsupported(String)
    case codec(CodecError)
}

/// Decodes `SpiceImage`s and maintains the pixmap and palette caches the server
/// manages remotely (`CACHE_ME`, `FROM_CACHE`, `INVAL_*`).
public struct ImageResolver: Sendable {
    /// Pixel budget announced to the server in `SPICE_MSGC_DISPLAY_INIT`.
    public let pixmapCacheBudget: Int
    public private(set) var pixmaps: [UInt64: PixelBuffer] = [:]
    public private(set) var palettes: [UInt64: Palette] = [:]
    static let maxCachedPalettes = 4096
    /// 1 Mi colours = 4 MiB across all cached palettes.
    static let maxPaletteEntries = 1 << 20
    private var paletteEntries = 0
    private var cachedPixels = 0
    /// GLZ's cross-image dictionary (window sized like the one announced to the server).
    private var glz = GLZDecoder(maxWindowPixels: 2 * Int(DisplayChannel.glzWindowSize))

    public init(pixmapCacheBudget: Int) {
        self.pixmapCacheBudget = pixmapCacheBudget
    }

    /// Resolves `image` to pixels. `surface` provides other surfaces for `SURFACE` images.
    public mutating func resolve(_ image: Image, surface: (UInt32) -> PixelBuffer?) throws(ImageResolveError) -> PixelBuffer {
        let descriptor = image.descriptor
        let pixels: PixelBuffer
        do {
            switch image.payload {
            case .fromCache:
                guard let cached = pixmaps[descriptor.id] else { throw ImageResolveError.cacheMiss(descriptor.id) }
                return cached
            case .surface(let id):
                guard let source = surface(id) else { throw ImageResolveError.unknownSurface(id) }
                return source
            case .bitmap(let bitmap):
                let palette = try resolvePalette(bitmap.palette, flags: bitmap.flags, required: bitmap.format.isPaletted)
                pixels = try BitmapDecoder.decode(bitmap, palette: palette)
            case .quic(let data):
                pixels = try QUICDecoder.decode(data)
            case .lzRGB(let data):
                pixels = try LZDecoder.decode(data)
            case .lzPLT(let lz):
                let palette = try resolvePalette(lz.palette, flags: lz.flags, required: true)
                pixels = try LZDecoder.decode(lz.data, palette: palette)
            case .jpeg(let data):
                #if canImport(ImageIO)
                pixels = try JPEGDecoder.decode(data)
                #else
                _ = data
                throw ImageResolveError.unsupported("jpeg")
                #endif
            case .jpegAlpha(let topDown, let jpegSize, let data):
                #if canImport(ImageIO)
                pixels = try JPEGDecoder.decodeWithAlpha(data, jpegSize: Int(jpegSize), topDown: topDown)
                #else
                _ = (topDown, jpegSize, data)
                throw ImageResolveError.unsupported("jpeg-alpha")
                #endif
            case .glzRGB(let data):
                pixels = try glz.decode(data)
            case .zlibGLZRGB(let glzSize, let data):
                #if canImport(Compression)
                pixels = try glz.decode(Zlib.inflate(data, expectedSize: Int(glzSize))[...])
                #else
                _ = (glzSize, data)
                throw ImageResolveError.unsupported("zlib-glz")
                #endif
            case .lz4(let data):
                pixels = try LZ4ImageDecoder.decode(data, width: Int(descriptor.width), height: Int(descriptor.height))
            }
        } catch let error as CodecError {
            throw .codec(error)
        } catch let error as ImageResolveError {
            throw error
        } catch {
            throw .unsupported("\(error)")
        }

        if descriptor.flags.contains(.cacheMe) || descriptor.flags.contains(.cacheReplaceMe) {
            store(pixels, id: descriptor.id)
        }
        return pixels
    }

    private mutating func resolvePalette(_ reference: PaletteReference, flags: BitmapFlags,
                                         required: Bool) throws(ImageResolveError) -> Palette? {
        switch reference {
        case .none:
            return nil
        case .inline(let palette):
            if flags.contains(.paletteCacheMe) {
                // Bounded: the server can mint unlimited unique ids. Dropping entries only
                // causes cache misses for a misbehaving server.
                // Bounded by count and by total entries (a palette can hold 65535 colours).
                let replaced = palettes[palette.unique]?.entries.count ?? 0
                if (palettes.count >= Self.maxCachedPalettes && replaced == 0)
                    || paletteEntries - replaced + palette.entries.count > Self.maxPaletteEntries {
                    palettes.removeAll()
                    paletteEntries = 0
                }
                paletteEntries += palette.entries.count - (palettes[palette.unique]?.entries.count ?? 0)
                palettes[palette.unique] = palette
            }
            return palette
        case .cached(let id):
            guard let palette = palettes[id] else {
                if required { throw .paletteCacheMiss(id) }
                return nil
            }
            return palette
        }
    }

    private mutating func store(_ image: PixelBuffer, id: UInt64) {
        if let old = pixmaps[id] { cachedPixels -= old.width * old.height }
        pixmaps[id] = image
        cachedPixels += image.width * image.height
        // The server tracks our cache and invalidates before we exceed the budget; this is
        // only a safety net against a misbehaving server.
        if cachedPixels > pixmapCacheBudget * 2 {
            pixmaps.removeAll()
            cachedPixels = 0
        }
    }

    public mutating func invalidatePixmap(_ id: UInt64) {
        if let old = pixmaps.removeValue(forKey: id) { cachedPixels -= old.width * old.height }
    }

    public mutating func invalidateAllPixmaps() {
        pixmaps.removeAll()
        cachedPixels = 0
    }

    public mutating func invalidatePalette(_ id: UInt64) {
        if let removed = palettes.removeValue(forKey: id) { paletteEntries -= removed.entries.count }
    }

    public mutating func invalidateAllPalettes() {
        palettes.removeAll()
        paletteEntries = 0
    }

    /// Decodes a QMask's 1-bpp bitmap (only uncompressed masks are supported).
    public func mask(for qmask: QMask) -> DrawMask? {
        guard let image = qmask.bitmap, case .bitmap(let bitmap) = image.payload,
              let decoded = try? BitmapDecoder.decodeMask(bitmap) else { return nil }
        return DrawMask(width: decoded.width, height: decoded.height, bits: decoded.bits,
                        inverted: qmask.inverted, origin: qmask.position)
    }
}
