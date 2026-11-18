import SpiceWire

/// Solid cosmetic stroke failures. Resource limits are checked before any pixel changes.
public enum StrokeError: Error, Equatable, Sendable {
    case invalidPath
    case unsupported
    case workLimit
}

extension PixelBuffer {
    /// Draws one-pixel, endpoint-exclusive solid cosmetic lines, cubics and closed figures.
    /// Curves are flattened with bounded fixed-point planning before pixels change.
    /// Styled paths remain a separate rendering contract. Clips form a union; path intersections retain
    /// the normal repeated raster operation, while shared endpoints are drawn once.
    @discardableResult
    public mutating func strokeSolid(path: StrokePath, brush: FillSource, box: Rect, clip: Clip,
                                     mode: Ropd, format: SurfaceFormat? = nil) throws(StrokeError) -> Rect {
        do { try path.validate() } catch { throw .invalidPath }
        let targetFormat = format ?? (hasAlpha ? .argb32 : .xRGB32)
        guard [.xRGB32, .argb32, .x555, .r565].contains(targetFormat), mode.rawValue & ~UInt16(0x7FF) == 0 else { throw .unsupported }
        let operations = mode.rawValue & 0x3F8
        guard operations.nonzeroBitCount <= 1 else { throw .unsupported }
        let rects = paintRects(box: box, clip: clip)
        let empty = Rect(x: 0, y: 0, width: 0, height: 0)
        guard !rects.isEmpty else { return empty }
        let region = rects.reduce(empty) { $0.union($1) }
        var lines: [(CosmeticLine, Range<Int>)] = []
        var current: Point?, first: Point?, work = 0
        var curveBudget = CubicStroke.Budget()
        func connect(to endpoint: Point) throws(StrokeError) {
            if let start = current {
                let line = CosmeticLine(from: start, to: endpoint)
                try Self.append(line, steps: line.visibleSteps(in: region), clipCount: rects.count,
                                into: &lines, work: &work)
            }
            current = endpoint
        }
        for segment in path.segments {
            var index = 0
            if segment.flags.contains(.begin) {
                current = segment.points[0].rounded; first = current; index = 1
            }
            if segment.flags.contains(.bezier) {
                while index < segment.points.count {
                    guard let start = current else { throw .invalidPath }
                    let controls = (segment.points[index], segment.points[index + 1], segment.points[index + 2])
                    let endpoints = try CubicStroke.flatten(from: start, controls: controls,
                                                            visible: region, budget: &curveBudget)
                    for endpoint in endpoints { try connect(to: endpoint) }
                    index += 3
                }
            } else {
                for point in segment.points.dropFirst(index) { try connect(to: point.rounded) }
            }
            if segment.flags.contains(.end) {
                if segment.flags.contains(.close), let first { try connect(to: first) }
                current = nil; first = nil
            }
        }
        let pattern: PixelBuffer?, origin: Point, solid: UInt32?
        switch brush {
        case .color(let color): pattern = nil; origin = Point(x: 0, y: 0); solid = color
        case .pattern(let image, let position):
            guard image.width > 0, image.height > 0 else { throw .invalidPath }
            pattern = image; origin = position; solid = nil
        }
        guard !lines.isEmpty else { return empty }
        var dirty = empty
        let rowWidth = width
        pixels.withUnsafeMutableBufferPointer { destination in
            for (line, steps) in lines {
                for index in steps {
                    let point = line.point(at: index)
                    guard rects.contains(where: { point.x >= Int($0.left) && point.x < Int($0.right) &&
                        point.y >= Int($0.top) && point.y < Int($0.bottom) }) else { continue }
                    let color: UInt32
                    if let solid { color = solid }
                    else if let pattern {
                        let x = ((point.x - Int(origin.x)) % pattern.width + pattern.width) % pattern.width
                        let y = ((point.y - Int(origin.y)) % pattern.height + pattern.height) % pattern.height
                        color = RasterPixelFormat.pack(pattern.pixels[y * pattern.width + x], format: targetFormat)
                    } else { continue }
                    let offset = point.y * rowWidth + point.x
                    let old = RasterPixelFormat.pack(destination[offset], format: targetFormat)
                    destination[offset] = RasterPixelFormat.expand(Self.strokeRop(mode, brush: color, destination: old), format: targetFormat)
                    dirty = dirty.union(Rect(x: point.x, y: point.y, width: 1, height: 1))
                }
            }
        }
        return dirty
    }

    private static func append(_ line: CosmeticLine, steps: Range<Int>, clipCount: Int,
                        into lines: inout [(CosmeticLine, Range<Int>)], work: inout Int) throws(StrokeError) {
        let visits = steps.count.multipliedReportingOverflow(by: clipCount)
        guard !visits.overflow, visits.partialValue <= 8 * 1024 * 1024 - work else { throw .workLimit }
        work += visits.partialValue
        if !steps.isEmpty {
            guard lines.count < 65_536 else { throw .workLimit }
            lines.append((line, steps))
        }
    }

    static func strokeRop(_ mode: Ropd, brush: UInt32, destination: UInt32) -> UInt32 {
        if mode.rawValue & 0x3F8 == 0 { return brush } // Reference default COPY ignores inversion-only flags.
        if mode.contains(.opBlackness) { return 0 }
        if mode.contains(.opWhiteness) { return .max }
        if mode.contains(.opInvers) { return ~destination }
        let source = mode.contains(.inversBrush) ? ~brush : brush
        let target = mode.contains(.inversDest) ? ~destination : destination
        var result: UInt32
        if mode.contains(.opOr) { result = source | target }
        else if mode.contains(.opAnd) { result = source & target }
        else if mode.contains(.opXor) { result = source ^ target }
        else { result = source }
        if mode.contains(.inversResult) { result = ~result }
        return result
    }
}
