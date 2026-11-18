import SpiceWire

/// Bounded fixed-point subdivision for cubic stroke paths. This helper
/// produces endpoints only; the caller completes all planning before touching pixels.
enum CubicStroke {
    struct Budget {
        let maxNodes: Int
        let maxEdges: Int
        let maxDepth: Int
        private(set) var usedNodes = 0
        private(set) var usedEdges = 0

        init(maxNodes: Int = 65_536, maxEdges: Int = 65_536, maxDepth: Int = 32) {
            self.maxNodes = maxNodes
            self.maxEdges = maxEdges
            self.maxDepth = maxDepth
        }

        mutating func visit() throws(StrokeError) {
            guard usedNodes < maxNodes else { throw .workLimit }
            usedNodes += 1
        }

        mutating func appendEdge() throws(StrokeError) {
            guard usedEdges < maxEdges else { throw .workLimit }
            usedEdges += 1
        }
    }

    /// Returns ordered leaf endpoints, excluding `start`. Start is the previous
    /// rounded cosmetic point reconstructed as fixed coordinates, as on the wire's
    /// reference rendering path. Counters are shared across every cubic in a draw.
    static func flatten(from start: Point, controls: (StrokePoint, StrokePoint, StrokePoint),
                        visible: Rect, budget: inout Budget) throws(StrokeError) -> [Point] {
        try subdivide(from: start, controls: controls, visible: visible, budget: &budget)
    }

    /// Styled geometry must retain every leaf, including invisible excursions,
    /// because each rounded leaf contributes to dash phase and later joins.
    static func flattenComplete(from start: Point, controls: (StrokePoint, StrokePoint, StrokePoint),
                                budget: inout Budget) throws(StrokeError) -> [Point] {
        try subdivide(from: start, controls: controls, visible: nil, budget: &budget)
    }

    private static func subdivide(from start: Point, controls: (StrokePoint, StrokePoint, StrokePoint),
                                  visible: Rect?, budget: inout Budget) throws(StrokeError) -> [Point] {
        let first = FixedPoint(x: Int64(start.x) * 16, y: Int64(start.y) * 16)
        // All caller starts must originate from a rounded signed 28.4 point. This
        // bound also proves every dot-product determinant below fits Int128.
        let coordinateLimit = Int64(Int32.max) + 1
        guard abs(first.x) <= coordinateLimit, abs(first.y) <= coordinateLimit else { throw .invalidPath }
        guard budget.maxDepth >= 0 else { throw .workLimit }
        var pending = [Piece(start: first, control1: FixedPoint(controls.0),
                             control2: FixedPoint(controls.1), end: FixedPoint(controls.2), depth: 0)]
        var endpoints: [Point] = []
        while let piece = pending.popLast() {
            try budget.visit()
            if visible.map({ piece.isOutside($0) }) == true || piece.isFlat {
                try budget.appendEdge()
                endpoints.append(piece.end.rounded)
                continue
            }
            guard piece.depth < budget.maxDepth else { throw .workLimit }
            // De Casteljau subdivision preserves the original control hull. Signed
            // fixed-point averages truncate toward zero; intermediates use Int64.
            let leftControl = piece.start.midpoint(piece.control1)
            let centerControl = piece.control1.midpoint(piece.control2)
            let rightControl = piece.control2.midpoint(piece.end)
            let leftInner = leftControl.midpoint(centerControl)
            let rightInner = centerControl.midpoint(rightControl)
            let join = leftInner.midpoint(rightInner)
            let nextDepth = piece.depth + 1
            // A LIFO stack receives right first to emit endpoints in path order.
            pending.append(Piece(start: join, control1: rightInner, control2: rightControl,
                                 end: piece.end, depth: nextDepth))
            pending.append(Piece(start: piece.start, control1: leftControl, control2: leftInner,
                                 end: join, depth: nextDepth))
        }
        return endpoints
    }

    private struct FixedPoint {
        let x: Int64
        let y: Int64
        init(x: Int64, y: Int64) { self.x = x; self.y = y }
        init(_ point: StrokePoint) { x = Int64(point.x); y = Int64(point.y) }
        var rounded: Point { Point(x: Int32((x + 7) >> 4), y: Int32((y + 7) >> 4)) }
        func midpoint(_ other: Self) -> Self { Self(x: (x + other.x) / 2, y: (y + other.y) / 2) }
    }

    private struct Piece {
        let start: FixedPoint
        let control1: FixedPoint
        let control2: FixedPoint
        let end: FixedPoint
        let depth: Int

        func isOutside(_ visible: Rect) -> Bool {
            guard !visible.isEmpty else { return true }
            // The curve stays inside its control hull. A one-pixel margin covers
            // cosmetic rounding; this shortcut is only valid for solid strokes,
            // not for computing a future dash phase or geometric curve length.
            let minX = min(start.x, control1.x, control2.x, end.x)
            let maxX = max(start.x, control1.x, control2.x, end.x)
            let minY = min(start.y, control1.y, control2.y, end.y)
            let maxY = max(start.y, control1.y, control2.y, end.y)
            return maxX < (Int64(visible.left) - 1) * 16 || minX > (Int64(visible.right) + 1) * 16
                || maxY < (Int64(visible.top) - 1) * 16 || minY > (Int64(visible.bottom) + 1) * 16
        }

        var isFlat: Bool {
            let roundedStart = start.rounded
            if control1.rounded == roundedStart, control2.rounded == roundedStart, end.rounded == roundedStart {
                // A convex hull inside one rounding cell cannot visit another pixel.
                // This also terminates the all-identical zero-chord reference case.
                return true
            }
            let chord = Vector(from: start, to: end)
            let rawLength = chord.dot(chord)
            guard rawLength > 0 else { return false }
            let first = Vector(from: start, to: control1)
            let second = Vector(from: start, to: control2)
            let firstProjection = first.dot(chord), secondProjection = second.dot(chord)
            guard firstProjection >= 0, firstProjection <= rawLength,
                  secondProjection >= 0, secondProjection <= rawLength else {
                // A purely perpendicular-distance test loses collinear excursions.
                return false
            }
            let quantizedLength = rawLength >> 4
            if quantizedLength == 0 {
                // A sub-quarter-pixel chord has a zero quantized norm. Use the same
                // half-square-pixel distance bound in raw units to avoid a fixed-
                // midpoint child repeating forever along a one-unit chord.
                let cross1 = first.cross(chord), cross2 = second.cross(chord)
                return cross1 * cross1 < 128 * rawLength && cross2 * cross2 < 128 * rawLength
            }
            let tail = Vector(from: end, to: control2)
            let reversedChord = Vector(from: end, to: start)
            let firstDot = first.dot(chord) >> 4
            let tailDot = tail.dot(reversedChord) >> 4
            // Quantizing each dot before the determinant is observable in the
            // pinned reference fixtures; plain floating-point distance is different.
            let firstError = (((first.dot(first) >> 4) * quantizedLength) - firstDot * firstDot) >> 3
            let tailError = (((tail.dot(tail) >> 4) * quantizedLength) - tailDot * tailDot) >> 3
            return firstError < quantizedLength && tailError < quantizedLength
        }
    }

    private struct Vector {
        let x: Int128
        let y: Int128
        init(from first: FixedPoint, to second: FixedPoint) {
            x = Int128(second.x) - Int128(first.x)
            y = Int128(second.y) - Int128(first.y)
        }
        func dot(_ other: Self) -> Int128 { x * other.x + y * other.y }
        func cross(_ other: Self) -> Int128 { x * other.y - y * other.x }
    }
}
