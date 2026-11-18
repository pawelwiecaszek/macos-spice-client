import SpiceWire

/// A standalone width-one geometric segment. Integer half-plane tests keep
/// distant clipped geometry exact; floating point only proposes candidate pixels.
struct StyledDiagonalSpan {
    let start: Point
    let dx: Int64
    let dy: Int64
    let squaredLength: Int64
    let length: Double

    init(start: Point, end: Point) {
        self.start = start
        dx = Int64(end.x) - Int64(start.x)
        dy = Int64(end.y) - Int64(start.y)
        squaredLength = dx * dx + dy * dy
        length = Double(squaredLength).squareRoot()
    }

    func candidates(y: Int, region: Rect) -> Range<Int> {
        let py = Int64(y) - Int64(start.y)
        let center = Double(py * dx) / Double(dy) + Double(start.x)
        let radius = length / (2 * Double(abs(dy)))
        // One extra candidate on either side absorbs rounding in these bounds;
        // exact half-plane tests below decide coverage without an epsilon.
        let low = max(Int(region.left), Int((center - radius).rounded(.down)) - 1)
        let high = min(Int(region.right), Int((center + radius).rounded(.up)) + 1)
        return high > low ? low..<high : 0..<0
    }

    func contains(x: Int, y: Int, dash: StrokeDashPattern) -> Bool {
        let px = Int64(x) - Int64(start.x), py = Int64(y) - Int64(start.y)
        let dot = px * dx + py * dy, cross = -px * dy + py * dx
        let forward = dx > 0
        guard forward ? dot >= 0 && dot < squaredLength : dot > 0 && dot <= squaredLength else { return false }
        let band = Int128(cross) * Int128(cross) * 4
        let squared = Int128(squaredLength)
        guard band <= squared else { return false }
        if band == squared {
            let lowerInclusive = dy < 0
            guard lowerInclusive ? cross < 0 : cross > 0 else { return false }
        }
        // Locate the integer Euclidean-distance cell. Exact squared comparisons
        // correct the floating estimate, including perfect-square dash boundaries.
        let dotSquared = Int128(dot) * Int128(dot)
        func boundary(_ value: Int64) -> Int128 { Int128(value) * Int128(value) * squared }
        var distance = Int64(Double(dot) / length)
        while boundary(distance) > dotSquared { distance -= 1 }
        while boundary(distance + 1) <= dotSquared { distance += 1 }
        if !forward, boundary(distance) == dotSquared { distance -= 1 }
        return dash.isForeground(at: distance)
    }
}

enum StyledStrokeCoverage {
    case axis(StyledAxisCoverage, figure: Int)
    case diagonal(StyledDiagonalSpan, y: Int, coordinates: Range<Int>, figure: Int)

    var figure: Int {
        switch self {
        case .axis(_, let figure), .diagonal(_, _, _, let figure): figure
        }
    }
}

/// Axis figures keep their verified joins. A figure containing a diagonal is
/// admitted only when it has one nonzero edge, so unverified joins stay atomic.
struct StyledStrokePlan {
    let coverage: [StyledStrokeCoverage]
    let region: Rect

    init(path: StrokePath, rects: [Rect], dash: StrokeDashPattern) throws(StrokeError) {
        do { try path.validate() } catch { throw .invalidPath }
        guard !path.segments.contains(where: { $0.flags.contains(.bezier) }) else { throw .unsupported }
        region = rects.reduce(Rect(x: 0, y: 0, width: 0, height: 0)) { $0.union($1) }
        let visible = region
        var result: [StyledStrokeCoverage] = [], work = 0, figure = 0, edgeCount = 0
        var segments: [StrokeSegment] = []
        func add(_ item: StyledStrokeCoverage, visits: Int) throws(StrokeError) {
            let amount = visits.multipliedReportingOverflow(by: rects.count)
            guard !amount.overflow, amount.partialValue <= 8 * 1024 * 1024 - work,
                  result.count < 131_072 else { throw .workLimit }
            work += amount.partialValue
            result.append(item)
        }
        func finish() throws(StrokeError) {
            guard !segments.isEmpty else { return }
            figure += 1
            var first: Point?, current: Point?, edges: [(Point, Point)] = []
            for segment in segments {
                var index = 0
                if segment.flags.contains(.begin) {
                    current = segment.points[0].rounded; first = current; index = 1
                }
                for point in segment.points.dropFirst(index) {
                    let endpoint = point.rounded
                    if let current, current != endpoint { edges.append((current, endpoint)) }
                    current = endpoint
                }
                if segment.flags.contains(.close), let current, let first, current != first {
                    edges.append((current, first))
                }
            }
            guard edges.count <= 65_536 - edgeCount else { throw .workLimit }
            edgeCount += edges.count
            if edges.contains(where: { $0.0.x != $0.1.x && $0.0.y != $0.1.y }) {
                guard edges.count == 1, let edge = edges.first else { throw .unsupported }
                let span = StyledDiagonalSpan(start: edge.0, end: edge.1)
                let low = max(Int(visible.top), min(Int(edge.0.y), Int(edge.1.y)) - 1)
                let high = min(Int(visible.bottom), max(Int(edge.0.y), Int(edge.1.y)) + 1)
                if high > low {
                    for y in low..<high {
                        let coordinates = span.candidates(y: y, region: visible)
                        // Count row traversal as well as candidate tests, even if
                        // a distant band misses this row's clipped x interval.
                        try add(.diagonal(span, y: y, coordinates: coordinates, figure: figure),
                                visits: coordinates.count + 1)
                    }
                }
            } else {
                let axis = try StyledAxisPlan(path: StrokePath(segments: segments), rects: rects, dash: dash)
                for item in axis.coverage {
                    let visits: Int
                    switch item { case .span(_, let range): visits = range.count; case .join: visits = 1 }
                    try add(.axis(item, figure: figure), visits: visits)
                }
            }
            segments.removeAll(keepingCapacity: true)
        }
        for segment in path.segments {
            if segment.flags.contains(.begin) { try finish() }
            segments.append(segment)
            if segment.flags.contains(.end) { try finish() }
        }
        try finish()
        coverage = result
    }
}
