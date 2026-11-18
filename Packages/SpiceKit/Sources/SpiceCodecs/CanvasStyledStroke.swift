import SpiceWire

extension PixelBuffer {
    /// Renders geometric styled figures, including bounded cubics and miter joins.
    /// Gaps stay transparent. Phase
    /// includes complete offscreen segments and resets at each figure boundary.
    @discardableResult
    public mutating func strokeStyled(path: StrokePath, attributes: StrokeAttributes, brush: FillSource,
                                      box: Rect, clip: Clip, mode: Ropd,
                                      format: SurfaceFormat? = nil) throws(StrokeError) -> Rect {
        let dash = try StrokeDashPattern(attributes: attributes)
        let targetFormat = format ?? (hasAlpha ? .argb32 : .xRGB32)
        guard [.xRGB32, .argb32, .x555, .r565].contains(targetFormat),
              mode.rawValue & ~UInt16(0x7FF) == 0, (mode.rawValue & 0x3F8).nonzeroBitCount <= 1 else { throw .unsupported }
        let rects = paintRects(box: box, clip: clip)
        let empty = Rect(x: 0, y: 0, width: 0, height: 0)
        guard !rects.isEmpty else { return empty }
        let idempotent = [UInt32(0), .max].allSatisfy { brushBit in
            [UInt32(0), .max].allSatisfy { destination in
                let once = Self.strokeRop(mode, brush: brushBit, destination: destination)
                return Self.strokeRop(mode, brush: brushBit, destination: once) == once
            }
        }
        let plan = try StyledStrokePlan(path: path, rects: rects, dash: dash, idempotent: idempotent)
        guard !plan.coverage.isEmpty else { return empty }
        let area = plan.region.width.multipliedReportingOverflow(by: plan.region.height)
        guard !area.overflow, area.partialValue <= pixels.count else { throw .workLimit }
        let pattern: PixelBuffer?, origin: Point, solid: UInt32?
        switch brush {
        case .color(let color): pattern = nil; origin = .init(x: 0, y: 0); solid = color
        case .pattern(let image, let position):
            guard image.width > 0, image.height > 0 else { throw .invalidPath }
            pattern = image; origin = position; solid = nil
        }
        let trackCoverage = plan.coverage.count > 1
        let wordCount = area.partialValue / 64 + (area.partialValue % 64 == 0 ? 0 : 1)
        var painted = trackCoverage ? [UInt64](repeating: 0, count: wordCount) : []
        var dirtyWords: [Int] = [], activeFigure: Int?, dirty = empty
        let rowWidth = width, region = plan.region
        pixels.withUnsafeMutableBufferPointer { destination in
            func paint(x: Int, y: Int) {
                guard rects.contains(where: { x >= Int($0.left) && x < Int($0.right) &&
                    y >= Int($0.top) && y < Int($0.bottom) }) else { return }
                if trackCoverage {
                    let index = (y - Int(region.top)) * region.width + x - Int(region.left)
                    let word = index >> 6, bit = UInt64(1) << (index & 63)
                    if painted[word] & bit != 0 { return }
                    if painted[word] == 0 { dirtyWords.append(word) }
                    painted[word] |= bit
                }
                let color: UInt32
                if let solid { color = solid }
                else if let pattern {
                    let px = ((x - Int(origin.x)) % pattern.width + pattern.width) % pattern.width
                    let py = ((y - Int(origin.y)) % pattern.height + pattern.height) % pattern.height
                    color = RasterPixelFormat.pack(pattern.pixels[py * pattern.width + px], format: targetFormat)
                } else { return }
                let index = y * rowWidth + x
                let old = RasterPixelFormat.pack(destination[index], format: targetFormat)
                destination[index] = RasterPixelFormat.expand(Self.strokeRop(mode, brush: color, destination: old), format: targetFormat)
                dirty = dirty.union(Rect(x: x, y: y, width: 1, height: 1))
            }
            for item in plan.coverage {
                if activeFigure != item.figure {
                    // Clearing only touched words bounds reset work by painted coverage,
                    // rather than clearing the whole surface for every tiny figure.
                    for word in dirtyWords { painted[word] = 0 }
                    dirtyWords.removeAll(keepingCapacity: true)
                    activeFigure = item.figure
                }
                switch item {
                case .axis(let axis, _):
                    switch axis {
                    case .span(let span, let coordinates):
                        for coordinate in coordinates where dash.isForeground(at: span.distance(at: coordinate)) {
                            paint(x: span.horizontal ? coordinate : span.fixed, y: span.horizontal ? span.fixed : coordinate)
                        }
                    case .join(let point, _): paint(x: Int(point.x), y: Int(point.y))
                    }
                case .diagonal(let span, let y, let coordinates, _):
                    for x in coordinates where span.contains(x: x, y: y, dash: dash) { paint(x: x, y: y) }
                case .join(let wedge, let y, let coordinates, _):
                    for x in coordinates where wedge.contains(x: x, y: y) { paint(x: x, y: y) }
                }
            }
        }
        return dirty
    }
}
