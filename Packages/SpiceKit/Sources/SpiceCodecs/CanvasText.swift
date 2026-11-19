import SpiceWire

public enum TextRasterError: Error, Equatable, Sendable {
    case unsupported
    case invalidGlyphs
    case workLimit
}

extension PixelBuffer {
    /// A1/A4/A8 glyphs in the declared row order. Coverage is united before
    /// foreground OVER; background uses COPY. Patterns are snapshots.
    @discardableResult
    public mutating func text(_ string: RasterString, foreground: FillSource?, background: FillSource?,
                                backgroundArea: Rect, box: Rect, clip: Clip, mode: Ropd,
                                format: SurfaceFormat? = nil) throws(TextRasterError) -> Rect {
        do { try string.validate() }
        catch WireError.limitExceeded { throw .workLimit }
        catch { throw .invalidGlyphs }
        let target = format ?? (hasAlpha ? .argb32 : .xRGB32)
        guard mode == .opPut,
              [.xRGB32, .argb32, .x555, .r565].contains(target) else { throw .unsupported }
        let native16 = target == .x555 || target == .r565
        for brush in [foreground, background] {
            if case .pattern(let image, _) = brush {
                guard image.width > 0, image.height > 0 else { throw .invalidGlyphs }
            }
        }
        let empty = Rect(x: 0, y: 0, width: 0, height: 0)
        let rects = paintRects(box: box, clip: clip)
        guard !rects.isEmpty else { return empty }
        let visible = rects.reduce(empty) { $0.union($1) }
        var glyphBounds: [Rect] = [], total = empty
        for glyph in string.glyphs {
            let bounds: Rect
            do { bounds = try glyph.bounds() } catch { throw .invalidGlyphs }
            glyphBounds.append(bounds)
            total = total.union(bounds)
        }
        let maskBounds = foreground == nil ? empty : total.intersection(visible)
        let backBounds = background == nil ? empty : backgroundArea.intersection(visible)
        let paintBounds = maskBounds.union(backBounds)
        guard !paintBounds.isEmpty else { return empty }
        let limit = 8 * 1024 * 1024
        let area = maskBounds.width.multipliedReportingOverflow(by: maskBounds.height)
        let paintArea = paintBounds.width.multipliedReportingOverflow(by: paintBounds.height)
        guard !area.overflow, area.partialValue <= limit, !paintArea.overflow else { throw .workLimit }
        let clipWork = paintArea.partialValue.multipliedReportingOverflow(by: rects.count)
        guard !clipWork.overflow, clipWork.partialValue <= limit else { throw .workLimit }
        var work = clipWork.partialValue
        for bounds in glyphBounds {
            let cropped = bounds.intersection(maskBounds)
            let visits = cropped.width * cropped.height
            guard visits <= limit - work else { throw .workLimit }
            work += visits
        }
        // All validation and work admission finishes before mutating the surface.
        var coverage = [UInt8](repeating: 0, count: area.partialValue)
        for (glyph, bounds) in zip(string.glyphs, glyphBounds) {
            let cropped = bounds.intersection(maskBounds)
            guard !cropped.isEmpty else { continue }
            let stride = (glyph.width * string.format.bitsPerPixel + 7) / 8
            for y in Int(cropped.top)..<Int(cropped.bottom) {
                let localRow = y - Int(bounds.top)
                let row = string.topDown ? localRow : glyph.height - 1 - localRow
                for x in Int(cropped.left)..<Int(cropped.right) {
                    let column = x - Int(bounds.left)
                    let value: UInt8
                    if string.format == .a1 {
                        value = glyph.data[row * stride + column / 8] & (0x80 >> (column & 7)) != 0 ? 255 : 0
                    } else if string.format == .a4 {
                        let byte = glyph.data[row * stride + column / 2]
                        value = column & 1 == 0 ? byte & 0xF0 : (byte & 0x0F) << 4
                    } else { value = glyph.data[row * stride + column] }
                    let index = (y - Int(maskBounds.top)) * maskBounds.width + x - Int(maskBounds.left)
                    coverage[index] = max(coverage[index], value)
                }
            }
        }
        func sample(_ brush: FillSource, x: Int, y: Int) -> UInt32 {
            switch brush {
            case .color(let value): return RasterPixelFormat.expand(value, format: target) | 0xFF00_0000
            case .pattern(let image, let origin):
                let px = ((x - Int(origin.x)) % image.width + image.width) % image.width
                let py = ((y - Int(origin.y)) % image.height + image.height) % image.height
                let value = image.pixels[py * image.width + px]
                return image.hasAlpha ? value : value | 0xFF00_0000
            }
        }
        func nativePixel(_ value: UInt32) -> UInt32 {
            if native16 { return RasterPixelFormat.expand(RasterPixelFormat.pack(value, format: target), format: target) }
            return target == .xRGB32 ? value | 0xFF00_0000 : value
        }
        var dirty = empty
        for y in Int(paintBounds.top)..<Int(paintBounds.bottom) {
            for x in Int(paintBounds.left)..<Int(paintBounds.right) {
                guard rects.contains(where: { x >= Int($0.left) && x < Int($0.right) &&
                    y >= Int($0.top) && y < Int($0.bottom) }) else { continue }
                var color: UInt32?
                if let background, x >= Int(backBounds.left), x < Int(backBounds.right),
                   y >= Int(backBounds.top), y < Int(backBounds.bottom) {
                    color = nativePixel(sample(background, x: x, y: y))
                }
                if let foreground, x >= Int(maskBounds.left), x < Int(maskBounds.right),
                   y >= Int(maskBounds.top), y < Int(maskBounds.bottom) {
                    let alpha = coverage[(y - Int(maskBounds.top)) * maskBounds.width + x - Int(maskBounds.left)]
                    if alpha != 0 {
                        let source = sample(foreground, x: x - Int(total.left), y: y - Int(total.top))
                        color = Self.blendOver(source: source, destination: color ?? nativePixel(pixels[y * width + x]),
                                               globalAlpha: UInt32(alpha))
                    }
                }
                if let color {
                    pixels[y * width + x] = nativePixel(color)
                    dirty = dirty.union(Rect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return dirty
    }
}
