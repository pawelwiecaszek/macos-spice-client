import SpiceWire

public enum TextRasterError: Error, Equatable, Sendable {
    case unsupported
    case invalidGlyphs
    case workLimit
}

extension PixelBuffer {
    /// Bottom-up MSB-first monochrome glyphs with opaque solid brushes. Glyph
    /// coverage is united before foreground painting; background uses COPY.
    @discardableResult
    public mutating func textA1(_ string: RasterString, foreground: UInt32?, background: UInt32?,
                                backgroundArea: Rect, box: Rect, clip: Clip, mode: Ropd,
                                format: SurfaceFormat? = nil) throws(TextRasterError) -> Rect {
        do { try string.validate() }
        catch WireError.limitExceeded { throw .workLimit }
        catch { throw .invalidGlyphs }
        let target = format ?? (hasAlpha ? .argb32 : .xRGB32)
        guard string.format == .a1, !string.topDown, mode == .opPut,
              [.xRGB32, .argb32, .x555, .r565].contains(target) else { throw .unsupported }
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
            let stride = (glyph.width + 7) / 8
            for y in Int(cropped.top)..<Int(cropped.bottom) {
                let row = glyph.height - 1 - (y - Int(bounds.top))
                for x in Int(cropped.left)..<Int(cropped.right) {
                    let column = x - Int(bounds.left)
                    if glyph.data[row * stride + column / 8] & (0x80 >> (column & 7)) != 0 {
                        coverage[(y - Int(maskBounds.top)) * maskBounds.width + x - Int(maskBounds.left)] = 1
                    }
                }
            }
        }
        let fore = foreground.map { RasterPixelFormat.expand($0, format: target) | 0xFF00_0000 }
        let back = background.map { RasterPixelFormat.expand($0, format: target) | 0xFF00_0000 }
        var dirty = empty
        for y in Int(paintBounds.top)..<Int(paintBounds.bottom) {
            for x in Int(paintBounds.left)..<Int(paintBounds.right) {
                guard rects.contains(where: { x >= Int($0.left) && x < Int($0.right) &&
                    y >= Int($0.top) && y < Int($0.bottom) }) else { continue }
                var color: UInt32?
                if let back, x >= Int(backBounds.left), x < Int(backBounds.right),
                   y >= Int(backBounds.top), y < Int(backBounds.bottom) { color = back }
                if let fore, x >= Int(maskBounds.left), x < Int(maskBounds.right),
                   y >= Int(maskBounds.top), y < Int(maskBounds.bottom),
                   coverage[(y - Int(maskBounds.top)) * maskBounds.width + x - Int(maskBounds.left)] != 0 { color = fore }
                if let color {
                    pixels[y * width + x] = color
                    dirty = dirty.union(Rect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return dirty
    }
}
