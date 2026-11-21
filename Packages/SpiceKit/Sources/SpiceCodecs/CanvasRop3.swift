import SpiceWire

extension PixelBuffer {
    /// Bounds clip traversal before drawing: at most eight bounding-area passes,
    /// capped at 64 Mi pixel visits except that one full bounding-area pass is allowed.
    /// This limits hostile repeated clips independently of the visited bitmap's memory.
    public func rop3WorkIsBounded(box: Rect, clip: Clip) -> Bool {
        Self.rop3WorkIsBounded(paintRects(box: box, clip: clip))
    }

    private static func rop3WorkIsBounded(_ rects: [Rect]) -> Bool {
        let region = rects.reduce(Rect(x: 0, y: 0, width: 0, height: 0)) { $0.union($1) }
        let area = region.width.multipliedReportingOverflow(by: region.height)
        guard !area.overflow else { return false }
        let expanded = area.partialValue.multipliedReportingOverflow(by: 8)
        guard !expanded.overflow else { return false }
        let limit = max(area.partialValue, min(64 * 1024 * 1024, expanded.partialValue))
        var visits = 0
        for rect in rects {
            let size = rect.width.multipliedReportingOverflow(by: rect.height)
            guard !size.overflow else { return false }
            let next = visits.addingReportingOverflow(size.partialValue)
            guard !next.overflow, next.partialValue <= limit else { return false }
            visits = next.partialValue
        }
        return true
    }

    /// Applies the eight-bit ternary truth table to pattern, source and destination.
    ///
    /// Each truth-table index is `(pattern << 2) | (source << 1) | destination`.
    /// Native x555/r565 operands are packed before evaluation; 32-bit ARGB includes
    /// alpha in the operation, while xRGB output is normalized to opaque BGRA.
    /// Interpolation is clamped to `sourceArea`, never adjacent image pixels.
    /// Overlapping clip rectangles paint once. Multiple clips use a bounded visited
    /// bitset over their bounding rectangle (at most one extra bit per surface pixel).
    @discardableResult
    public mutating func rop3(from source: PixelBuffer, sourceArea: Rect, brush: FillSource,
                              box: Rect, clip: Clip, rop: UInt8, scaleMode: ScaleMode = .nearest,
                              mask: DrawMask? = nil, format: SurfaceFormat? = nil) -> Rect {
        let empty = Rect(left: 0, top: 0, right: 0, bottom: 0)
        let targetFormat = format ?? (hasAlpha ? .argb32 : .xRGB32)
        guard [.xRGB32, .argb32, .x555, .r565].contains(targetFormat),
              Self.isValid(sourceArea, in: source), !box.isEmpty else { return empty }
        if let mask {
            let size = mask.width.multipliedReportingOverflow(by: mask.height)
            guard mask.width > 0, mask.height > 0, !size.overflow, size.partialValue == mask.bits.count else { return empty }
        }
        let pattern: PixelBuffer
        let origin: Point
        let solid: UInt32?
        switch brush {
        case .color(let color):
            solid = color
            pattern = PixelBuffer(width: 0, height: 0)
            origin = Point(x: 0, y: 0)
        case .pattern(let image, let position):
            guard image.width > 0, image.height > 0 else { return empty }
            solid = nil
            pattern = image
            origin = position
        }
        let rects = paintRects(box: box, clip: clip)
        guard !rects.isEmpty, Self.rop3WorkIsBounded(rects) else { return empty }
        let region = rects.reduce(empty) { $0.union($1) }
        let area = region.width.multipliedReportingOverflow(by: region.height)
        guard !area.overflow, area.partialValue <= pixels.count else { return empty }
        var visited = rects.count > 1 ? [UInt64](repeating: 0, count: area.partialValue / 64 + (area.partialValue % 64 == 0 ? 0 : 1)) : []
        let table = Rop3Table(rop)
        let scaled = sourceArea.width != box.width || sourceArea.height != box.height
        let destinationWidth = width
        var dirty = empty
        source.pixels.withUnsafeBufferPointer { src in
            pattern.pixels.withUnsafeBufferPointer { pat in
                pixels.withUnsafeMutableBufferPointer { dst in
                    for rect in rects {
                        for y in Int(rect.top)..<Int(rect.bottom) {
                            let by = y - Int(box.top)
                            var first = Int(rect.right), last = Int(rect.left)
                            for x in Int(rect.left)..<Int(rect.right) {
                                let bx = x - Int(box.left)
                                if let mask {
                                    // Inversion changes bitmap bits, not the bitmap's extent.
                                    let mx = bx + Int(mask.origin.x), my = by + Int(mask.origin.y)
                                    guard mx >= 0, my >= 0, mx < mask.width, my < mask.height,
                                          mask.allows(boxX: bx, boxY: by) else { continue }
                                }
                                if !visited.isEmpty {
                                    let index = (y - Int(region.top)) * region.width + x - Int(region.left)
                                    let word = index >> 6, bit = UInt64(1) << (index & 63)
                                    if visited[word] & bit != 0 { continue }
                                    visited[word] |= bit
                                }
                                let sample: UInt32
                                if scaled, scaleMode == .interpolate {
                                    sample = Self.rop3Interpolated(src, sourceWidth: source.width, area: sourceArea,
                                                                   box: box, bx: bx, by: by, format: targetFormat)
                                } else {
                                    let sx = Int(sourceArea.left) + ((2 * bx + 1) * sourceArea.width) / (2 * box.width)
                                    let sy = Int(sourceArea.top) + ((2 * by + 1) * sourceArea.height) / (2 * box.height)
                                    sample = src[sy * source.width + sx]
                                }
                                let patternValue: UInt32
                                if let solid {
                                    patternValue = solid // Solid brushes are already in the target format.
                                } else {
                                    let px = ((x - Int(origin.x)) % pattern.width + pattern.width) % pattern.width
                                    let py = ((y - Int(origin.y)) % pattern.height + pattern.height) % pattern.height
                                    patternValue = RasterPixelFormat.pack(pat[py * pattern.width + px], format: targetFormat)
                                }
                                let index = y * destinationWidth + x
                                let value = table.apply(pattern: patternValue,
                                    source: RasterPixelFormat.pack(sample, format: targetFormat),
                                    destination: RasterPixelFormat.pack(dst[index], format: targetFormat))
                                dst[index] = RasterPixelFormat.expand(value, format: targetFormat)
                                first = min(first, x); last = x + 1
                            }
                            if last > first {
                                dirty = dirty.union(Rect(x: first, y: y, width: last - first, height: 1))
                            }
                        }
                    }
                }
            }
        }
        return dirty
    }

    private static func rop3Interpolated(_ source: UnsafeBufferPointer<UInt32>, sourceWidth: Int,
                                         area: Rect, box: Rect, bx: Int, by: Int, format: SurfaceFormat) -> UInt32 {
        let fx = (Double(bx) + 0.5) * Double(area.width) / Double(box.width) - 0.5 + Double(area.left)
        let fy = (Double(by) + 0.5) * Double(area.height) / Double(box.height) - 0.5 + Double(area.top)
        let x0 = max(Int(area.left), min(Int(area.right) - 1, Int(fx.rounded(.down))))
        let y0 = max(Int(area.top), min(Int(area.bottom) - 1, Int(fy.rounded(.down))))
        let x1 = min(Int(area.right) - 1, x0 + 1), y1 = min(Int(area.bottom) - 1, y0 + 1)
        let wx = UInt32(max(0, min(256, Int((fx - Double(x0)) * 256))))
        let wy = UInt32(max(0, min(256, Int((fy - Double(y0)) * 256))))
        // Native 16-bit targets quantize contributing samples before scaling.
        let a = RasterPixelFormat.expand(RasterPixelFormat.pack(source[y0 * sourceWidth + x0], format: format), format: format)
        let b = RasterPixelFormat.expand(RasterPixelFormat.pack(source[y0 * sourceWidth + x1], format: format), format: format)
        let c = RasterPixelFormat.expand(RasterPixelFormat.pack(source[y1 * sourceWidth + x0], format: format), format: format)
        let d = RasterPixelFormat.expand(RasterPixelFormat.pack(source[y1 * sourceWidth + x1], format: format), format: format)
        var result: UInt32 = 0
        for shift in stride(from: UInt32(0), to: 32, by: 8) {
            let top = ((a >> shift) & 255) * (256 - wx) + ((b >> shift) & 255) * wx
            let bottom = ((c >> shift) & 255) * (256 - wx) + ((d >> shift) & 255) * wx
            result |= ((top * (256 - wy) + bottom * wy) >> 16) << shift
        }
        return result
    }
}

/// Shannon expansion evaluates all 32 bit positions together, without per-bit loops.
private struct Rop3Table {
    let a: UInt32, b: UInt32, c: UInt32, d: UInt32
    let e: UInt32, f: UInt32, g: UInt32, h: UInt32

    init(_ value: UInt8) {
        a = value & 1 == 0 ? 0 : .max; b = value & 2 == 0 ? 0 : .max
        c = value & 4 == 0 ? 0 : .max; d = value & 8 == 0 ? 0 : .max
        e = value & 16 == 0 ? 0 : .max; f = value & 32 == 0 ? 0 : .max
        g = value & 64 == 0 ? 0 : .max; h = value & 128 == 0 ? 0 : .max
    }

    @inline(__always)
    func apply(pattern p: UInt32, source s: UInt32, destination d0: UInt32) -> UInt32 {
        let ab = a ^ (d0 & (a ^ b)), cd = c ^ (d0 & (c ^ d))
        let ef = e ^ (d0 & (e ^ f)), gh = g ^ (d0 & (g ^ h))
        let low = ab ^ (s & (ab ^ cd)), high = ef ^ (s & (ef ^ gh))
        return low ^ (p & (low ^ high))
    }
}
