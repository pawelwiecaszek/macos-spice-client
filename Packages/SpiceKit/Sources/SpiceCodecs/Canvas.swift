import SpiceWire

/// A decoded 1-bpp mask positioned relative to the drawing box.
public struct DrawMask: Sendable {
    public var width: Int
    public var height: Int
    public var bits: [Bool]
    public var inverted: Bool
    /// Mask pixel that corresponds to the top-left of the box.
    public var origin: Point

    public init(width: Int, height: Int, bits: [Bool], inverted: Bool, origin: Point) {
        self.width = width
        self.height = height
        self.bits = bits
        self.inverted = inverted
        self.origin = origin
    }

    @inline(__always)
    func allows(boxX: Int, boxY: Int) -> Bool {
        let mx = boxX + Int(origin.x), my = boxY + Int(origin.y)
        let bit = mx >= 0 && my >= 0 && mx < width && my < height ? bits[my * width + mx] : false
        return bit != inverted
    }
}

/// Fill source for `fill(…)`.
public enum FillSource: Sendable {
    case color(UInt32)
    case pattern(PixelBuffer, origin: Point)
}

/// Software raster operations on a surface (`PixelBuffer`), mirroring SPICE draw commands.
///
/// All operations clip to the surface, the command's box and its clip rects, and return
/// the rectangle that was actually modified (for dirty tracking).
extension PixelBuffer {
    public var bounds: Rect { Rect(x: 0, y: 0, width: width, height: height) }

    /// Rectangles to paint: box ∩ clip ∩ surface bounds.
    public func paintRects(box: Rect, clip: Clip) -> [Rect] {
        let boxed = box.intersection(bounds)
        guard !boxed.isEmpty else { return [] }
        switch clip {
        case .none:
            return [boxed]
        case .rects(let rects):
            return rects.compactMap { rect in
                let r = rect.intersection(boxed)
                return r.isEmpty ? nil : r
            }
        }
    }

    // MARK: Raster-op helpers

    /// Applies a SPICE ROP descriptor to RGB, keeping the destination alpha unless the
    /// operation is a plain copy.
    @inline(__always)
    static func applyRop(_ rop: Ropd, source: UInt32, destination: UInt32) -> UInt32 {
        if rop.contains(.opBlackness) { return destination & 0xFF00_0000 }
        if rop.contains(.opWhiteness) { return destination | 0x00FF_FFFF }
        if rop.contains(.opInvers) { return destination ^ 0x00FF_FFFF }
        var src = source
        var dst = destination
        if rop.contains(.inversSource) || rop.contains(.inversBrush) { src ^= 0x00FF_FFFF }
        if rop.contains(.inversDest) { dst ^= 0x00FF_FFFF }
        var result: UInt32
        if rop.contains(.opOr) {
            result = (dst & 0xFF00_0000) | ((src | dst) & 0x00FF_FFFF)
        } else if rop.contains(.opAnd) {
            result = (dst & 0xFF00_0000) | ((src & dst) & 0x00FF_FFFF)
        } else if rop.contains(.opXor) {
            result = (dst & 0xFF00_0000) | ((src ^ dst) & 0x00FF_FFFF)
        } else {
            result = src  // OP_PUT (and the default)
        }
        if rop.contains(.inversResult) { result ^= 0x00FF_FFFF }
        return result
    }

    /// `true` when `area` is non-empty and lies inside `source` (rejects hostile rects
    /// before any scaling arithmetic).
    @inline(__always)
    static func isValid(_ area: Rect, in source: PixelBuffer) -> Bool {
        area.left >= 0 && area.top >= 0 && area.right > area.left && area.bottom > area.top
            && Int(area.right) <= source.width && Int(area.bottom) <= source.height
    }

    @inline(__always)
    static func isPlainCopy(_ rop: Ropd) -> Bool {
        rop == .opPut || rop.isEmpty
    }

    // MARK: Fill / blackness / whiteness / invers

    @discardableResult
    public mutating func fill(box: Rect, clip: Clip, source: FillSource, rop: Ropd = .opPut,
                              mask: DrawMask? = nil) -> Rect {
        var dirty = Rect(left: 0, top: 0, right: 0, bottom: 0)
        let w = width
        for rect in paintRects(box: box, clip: clip) {
            dirty = dirty.union(rect)
            pixels.withUnsafeMutableBufferPointer { dst in
                for y in Int(rect.top)..<Int(rect.bottom) {
                    let row = y * w
                    for x in Int(rect.left)..<Int(rect.right) {
                        if let mask, !mask.allows(boxX: x - Int(box.left), boxY: y - Int(box.top)) { continue }
                        let color: UInt32
                        switch source {
                        case .color(let value):
                            color = 0xFF00_0000 | value
                        case .pattern(let pattern, let origin):
                            guard pattern.width > 0, pattern.height > 0 else { continue }
                            let px = ((x - Int(origin.x)) % pattern.width + pattern.width) % pattern.width
                            let py = ((y - Int(origin.y)) % pattern.height + pattern.height) % pattern.height
                            color = pattern.pixels[py * pattern.width + px]
                        }
                        dst[row + x] = Self.isPlainCopy(rop) ? color : Self.applyRop(rop, source: color, destination: dst[row + x])
                    }
                }
            }
        }
        return dirty
    }

    @discardableResult
    public mutating func applyUnary(box: Rect, clip: Clip, rop: Ropd, mask: DrawMask? = nil) -> Rect {
        var dirty = Rect(left: 0, top: 0, right: 0, bottom: 0)
        let w = width
        for rect in paintRects(box: box, clip: clip) {
            dirty = dirty.union(rect)
            pixels.withUnsafeMutableBufferPointer { dst in
                for y in Int(rect.top)..<Int(rect.bottom) {
                    for x in Int(rect.left)..<Int(rect.right) {
                        if let mask, !mask.allows(boxX: x - Int(box.left), boxY: y - Int(box.top)) { continue }
                        dst[y * w + x] = Self.applyRop(rop, source: 0, destination: dst[y * w + x])
                    }
                }
            }
        }
        return dirty
    }

    // MARK: Copy / blend

    /// `DRAW_COPY` / `DRAW_BLEND` / `DRAW_OPAQUE` (without brush): copies `sourceArea` of
    /// `source` into `box`, scaling if the sizes differ.
    @discardableResult
    public mutating func copy(from source: PixelBuffer, sourceArea: Rect, box: Rect, clip: Clip,
                              rop: Ropd = .opPut, scaleMode: ScaleMode = .nearest,
                              mask: DrawMask? = nil) -> Rect {
        guard Self.isValid(sourceArea, in: source), box.width > 0, box.height > 0 else {
            return Rect(left: 0, top: 0, right: 0, bottom: 0)
        }
        let scaled = sourceArea.width != box.width || sourceArea.height != box.height
        let plain = Self.isPlainCopy(rop)
        var dirty = Rect(left: 0, top: 0, right: 0, bottom: 0)
        let w = width
        for rect in paintRects(box: box, clip: clip) {
            dirty = dirty.union(rect)
            // Fast path: unscaled, unmasked copy → row memcpy (decoders emit opaque alpha for
            // sources without an alpha channel, so no per-pixel fix-up is needed).
            let sx0 = Int(sourceArea.left) + Int(rect.left) - Int(box.left)
            let sy0 = Int(sourceArea.top) + Int(rect.top) - Int(box.top)
            if !scaled, plain, mask == nil, sx0 >= 0, sy0 >= 0,
               sx0 + rect.width <= source.width, sy0 + rect.height <= source.height {
                pixels.withUnsafeMutableBufferPointer { dst in
                    source.pixels.withUnsafeBufferPointer { src in
                        guard let d = dst.baseAddress, let s = src.baseAddress else { return }
                        for row in 0..<rect.height {
                            (d + (Int(rect.top) + row) * w + Int(rect.left))
                                .update(from: s + (sy0 + row) * source.width + sx0, count: rect.width)
                        }
                    }
                }
                continue
            }
            pixels.withUnsafeMutableBufferPointer { dst in
                source.pixels.withUnsafeBufferPointer { src in
                    for y in Int(rect.top)..<Int(rect.bottom) {
                        let by = y - Int(box.top)
                        for x in Int(rect.left)..<Int(rect.right) {
                            let bx = x - Int(box.left)
                            if let mask, !mask.allows(boxX: bx, boxY: by) { continue }
                            let color: UInt32
                            if !scaled {
                                let sx = Int(sourceArea.left) + bx, sy = Int(sourceArea.top) + by
                                guard sx >= 0, sy >= 0, sx < source.width, sy < source.height else { continue }
                                color = src[sy * source.width + sx]
                            } else if scaleMode == .interpolate {
                                color = Self.sampleBilinear(src, width: source.width, height: source.height,
                                                            area: sourceArea, box: box, bx: bx, by: by)
                            } else {
                                let sx = Int(sourceArea.left) + bx * sourceArea.width / box.width
                                let sy = Int(sourceArea.top) + by * sourceArea.height / box.height
                                guard sx >= 0, sy >= 0, sx < source.width, sy < source.height else { continue }
                                color = src[sy * source.width + sx]
                            }
                            let opaqueColor = source.hasAlpha ? color : (color | 0xFF00_0000)
                            dst[y * w + x] = plain ? opaqueColor : Self.applyRop(rop, source: opaqueColor, destination: dst[y * w + x])
                        }
                    }
                }
            }
        }
        return dirty
    }

    @inline(__always)
    static func sampleBilinear(_ src: UnsafeBufferPointer<UInt32>, width: Int, height: Int,
                               area: Rect, box: Rect, bx: Int, by: Int) -> UInt32 {
        // Map pixel centres; 8-bit fixed-point weights.
        let fx = (Double(bx) + 0.5) * Double(area.width) / Double(box.width) - 0.5 + Double(area.left)
        let fy = (Double(by) + 0.5) * Double(area.height) / Double(box.height) - 0.5 + Double(area.top)
        let x0 = max(0, min(width - 1, Int(fx.rounded(.down))))
        let y0 = max(0, min(height - 1, Int(fy.rounded(.down))))
        let x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
        let wx = UInt32(max(0, min(256, Int((fx - Double(x0)) * 256))))
        let wy = UInt32(max(0, min(256, Int((fy - Double(y0)) * 256))))
        let p00 = src[y0 * width + x0], p10 = src[y0 * width + x1]
        let p01 = src[y1 * width + x0], p11 = src[y1 * width + x1]
        var out: UInt32 = 0
        for shift in stride(from: UInt32(0), to: 32, by: 8) {
            let c00 = (p00 >> shift) & 0xFF, c10 = (p10 >> shift) & 0xFF
            let c01 = (p01 >> shift) & 0xFF, c11 = (p11 >> shift) & 0xFF
            let top = c00 * (256 - wx) + c10 * wx
            let bottom = c01 * (256 - wx) + c11 * wx
            let value = (top * (256 - wy) + bottom * wy) >> 16
            out |= min(value, 255) << shift
        }
        return out
    }

    // MARK: Copy bits

    /// `COPY_BITS`: copies from `sourcePosition` to `box` within this surface.
    ///
    /// The source area is snapshotted first, so overlapping moves (scrolling) and multiple
    /// clip rects never read pixels this operation already overwrote.
    @discardableResult
    public mutating func copyBits(sourcePosition: Point, box: Rect, clip: Clip) -> Rect {
        let dx = Int(box.left) - Int(sourcePosition.x)
        let dy = Int(box.top) - Int(sourcePosition.y)
        let rects = paintRects(box: box, clip: clip)
        guard !rects.isEmpty else { return Rect(left: 0, top: 0, right: 0, bottom: 0) }
        let union = rects.reduce(Rect(left: 0, top: 0, right: 0, bottom: 0)) { $0.union($1) }
        let sourceUnion = union.shifted(dx: -dx, dy: -dy).intersection(bounds)
        guard !sourceUnion.isEmpty else { return Rect(left: 0, top: 0, right: 0, bottom: 0) }
        let snapshot = cropped(x: Int(sourceUnion.left), y: Int(sourceUnion.top),
                               width: sourceUnion.width, height: sourceUnion.height)
        var dirty = Rect(left: 0, top: 0, right: 0, bottom: 0)
        let w = width
        for rect in rects {
            // Only the part whose source lies inside the surface can be copied.
            let target = rect.intersection(sourceUnion.shifted(dx: dx, dy: dy))
            guard !target.isEmpty else { continue }
            dirty = dirty.union(target)
            pixels.withUnsafeMutableBufferPointer { dst in
                for y in Int(target.top)..<Int(target.bottom) {
                    let sy = y - dy - Int(sourceUnion.top)
                    let sx0 = Int(target.left) - dx - Int(sourceUnion.left)
                    for x in 0..<target.width {
                        dst[y * w + Int(target.left) + x] = snapshot.pixels[sy * snapshot.width + sx0 + x]
                    }
                }
            }
        }
        return dirty
    }

    // MARK: Alpha blend / transparent

    /// `DRAW_ALPHA_BLEND`: premultiplied source-over with a global alpha.
    @discardableResult
    public mutating func alphaBlend(from source: PixelBuffer, sourceArea: Rect, box: Rect, clip: Clip,
                                    alpha: UInt8, sourceHasAlpha: Bool) -> Rect {
        guard Self.isValid(sourceArea, in: source), box.width > 0, box.height > 0 else {
            return Rect(left: 0, top: 0, right: 0, bottom: 0)
        }
        var dirty = Rect(left: 0, top: 0, right: 0, bottom: 0)
        let w = width
        let global = UInt32(alpha)
        for rect in paintRects(box: box, clip: clip) {
            dirty = dirty.union(rect)
            pixels.withUnsafeMutableBufferPointer { dst in
                for y in Int(rect.top)..<Int(rect.bottom) {
                    let by = y - Int(box.top)
                    let sy = Int(sourceArea.top) + by * sourceArea.height / box.height
                    guard sy >= 0, sy < source.height else { continue }
                    for x in Int(rect.left)..<Int(rect.right) {
                        let bx = x - Int(box.left)
                        let sx = Int(sourceArea.left) + bx * sourceArea.width / box.width
                        guard sx >= 0, sx < source.width else { continue }
                        var s = source.pixels[sy * source.width + sx]
                        if !sourceHasAlpha { s |= 0xFF00_0000 }
                        dst[y * w + x] = Self.blendOver(source: s, destination: dst[y * w + x], globalAlpha: global)
                    }
                }
            }
        }
        return dirty
    }

    /// Premultiplied OVER with an extra global alpha multiplier.
    @inline(__always)
    static func blendOver(source: UInt32, destination: UInt32, globalAlpha: UInt32) -> UInt32 {
        func scale(_ c: UInt32, _ a: UInt32) -> UInt32 { (c * a + 127) / 255 }
        let sa = scale(source >> 24, globalAlpha)
        let inv = 255 - sa
        var out: UInt32 = 0
        for shift in stride(from: UInt32(0), to: 24, by: 8) {
            let s = scale((source >> shift) & 0xFF, globalAlpha)
            let d = (destination >> shift) & 0xFF
            out |= min(255, s + scale(d, inv)) << shift
        }
        let da = destination >> 24
        out |= min(255, sa + scale(da, inv)) << 24
        return out
    }

    /// `DRAW_TRANSPARENT`: copies pixels whose RGB differs from `colorKey`.
    @discardableResult
    public mutating func transparentCopy(from source: PixelBuffer, sourceArea: Rect, box: Rect, clip: Clip,
                                         colorKey: UInt32) -> Rect {
        guard Self.isValid(sourceArea, in: source), box.width > 0, box.height > 0 else {
            return Rect(left: 0, top: 0, right: 0, bottom: 0)
        }
        var dirty = Rect(left: 0, top: 0, right: 0, bottom: 0)
        let key = colorKey & 0x00FF_FFFF
        let w = width
        for rect in paintRects(box: box, clip: clip) {
            dirty = dirty.union(rect)
            pixels.withUnsafeMutableBufferPointer { dst in
                for y in Int(rect.top)..<Int(rect.bottom) {
                    let sy = Int(sourceArea.top) + (y - Int(box.top)) * sourceArea.height / box.height
                    guard sy >= 0, sy < source.height else { continue }
                    for x in Int(rect.left)..<Int(rect.right) {
                        let sx = Int(sourceArea.left) + (x - Int(box.left)) * sourceArea.width / box.width
                        guard sx >= 0, sx < source.width else { continue }
                        let s = source.pixels[sy * source.width + sx]
                        if s & 0x00FF_FFFF != key { dst[y * w + x] = s | 0xFF00_0000 }
                    }
                }
            }
        }
        return dirty
    }
}

extension Rect {
    /// Offset with saturating `Int` arithmetic (safe for hostile coordinates).
    func shifted(dx: Int, dy: Int) -> Rect {
        Rect(left: Int32(clamping: Int(left) + dx), top: Int32(clamping: Int(top) + dy),
             right: Int32(clamping: Int(right) + dx), bottom: Int32(clamping: Int(bottom) + dy))
    }
}
