import SpiceWire

/// A width-one axis-aligned geometric span, not a zero-width cosmetic line.
struct StyledAxisSpan {
    let start: Point
    let end: Point
    let horizontal: Bool
    let increasing: Bool
    let length: Int
    let phase: Int64
    let figure: Int

    init(from start: Point, to end: Point, phase: Int64, figure: Int) throws(StrokeError) {
        guard start.x == end.x || start.y == end.y else { throw .unsupported }
        self.start = start; self.end = end; self.phase = phase; self.figure = figure
        horizontal = start.y == end.y
        let first = Int(horizontal ? start.x : start.y), last = Int(horizontal ? end.x : end.y)
        increasing = last >= first
        length = abs(last - first)
    }

    var fixed: Int { Int(horizontal ? start.y : start.x) }
    var first: Int { Int(horizontal ? start.x : start.y) }
    var last: Int { Int(horizontal ? end.x : end.y) }

    func range(in region: Rect) -> Range<Int> {
        let minorStart = Int(horizontal ? region.top : region.left)
        let minorEnd = Int(horizontal ? region.bottom : region.right)
        guard fixed >= minorStart, fixed < minorEnd else { return 0..<0 }
        let low = max(min(first, last), Int(horizontal ? region.left : region.top))
        let high = min(max(first, last), Int(horizontal ? region.right : region.bottom))
        return high > low ? low..<high : 0..<0
    }

    func distance(at coordinate: Int) -> Int64 {
        phase + Int64(increasing ? coordinate - first : first - coordinate - 1)
    }
}

enum StyledAxisCoverage {
    case span(StyledAxisSpan, Range<Int>)
    case join(Point, figure: Int)
    var figure: Int {
        switch self { case .span(let span, _): span.figure; case .join(_, let figure): figure }
    }
}

/// Complete geometry/phase planning precedes pixel mutation. Huge clipped distances
/// advance phase analytically instead of walking invisible dashes.
struct StyledAxisPlan {
    let coverage: [StyledAxisCoverage]
    let region: Rect

    init(path: StrokePath, rects: [Rect], dash: StrokeDashPattern) throws(StrokeError) {
        do { try path.validate() } catch { throw .invalidPath }
        guard !path.segments.contains(where: { $0.flags.contains(.bezier) }) else { throw .unsupported }
        region = rects.reduce(Rect(x: 0, y: 0, width: 0, height: 0)) { $0.union($1) }
        let visible = region
        var result: [StyledAxisCoverage] = [], work = 0
        var current: Point?, beginning: Point?, firstSpan: StyledAxisSpan?, lastSpan: StyledAxisSpan?
        var phase: Int64 = 0, figure = 0, spanCount = 0
        func add(_ item: StyledAxisCoverage, visits: Int) throws(StrokeError) {
            let amount = visits.multipliedReportingOverflow(by: rects.count)
            guard !amount.overflow, amount.partialValue <= 8 * 1024 * 1024 - work,
                  result.count < 131_072 else { throw .workLimit }
            work += amount.partialValue
            result.append(item)
        }
        func join(_ incoming: StyledAxisSpan, _ outgoing: StyledAxisSpan) throws(StrokeError) {
            guard incoming.horizontal != outgoing.horizontal, incoming.increasing, !outgoing.increasing,
                  dash.foregroundBeforeEndpoint(at: incoming.phase + Int64(incoming.length)),
                  dash.isForeground(at: outgoing.phase) else { return }
            let p = incoming.end
            if Int(p.x) >= Int(visible.left), Int(p.x) < Int(visible.right),
               Int(p.y) >= Int(visible.top), Int(p.y) < Int(visible.bottom) {
                try add(.join(p, figure: incoming.figure), visits: 1)
            }
        }
        func connect(_ endpoint: Point) throws(StrokeError) {
            guard let start = current else { throw .invalidPath }
            let span = try StyledAxisSpan(from: start, to: endpoint, phase: phase, figure: figure)
            current = endpoint
            guard span.length > 0 else { return }
            guard spanCount < 65_536 else { throw .workLimit }
            spanCount += 1
            if let lastSpan { try join(lastSpan, span) }
            if firstSpan == nil { firstSpan = span }
            lastSpan = span
            let steps = span.range(in: visible)
            if !steps.isEmpty { try add(.span(span, steps), visits: steps.count) }
            phase += Int64(span.length)
        }
        func finish() throws(StrokeError) {
            if current == beginning, let lastSpan, let firstSpan { try join(lastSpan, firstSpan) }
            current = nil; beginning = nil; firstSpan = nil; lastSpan = nil
        }
        for segment in path.segments {
            var index = 0
            if segment.flags.contains(.begin) {
                try finish(); figure += 1; phase = 0
                current = segment.points[0].rounded; beginning = current; index = 1
            }
            for point in segment.points.dropFirst(index) { try connect(point.rounded) }
            if segment.flags.contains(.end) {
                if segment.flags.contains(.close), let beginning { try connect(beginning) }
                try finish()
            }
        }
        try finish()
        coverage = result
    }
}
