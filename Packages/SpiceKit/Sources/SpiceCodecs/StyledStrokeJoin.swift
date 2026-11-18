import SpiceWire

/// The outside wedge between two butt-capped width-one segment rectangles.
/// Work stays within six pixels of the vertex because longer miters are beveled.
struct StyledStrokeJoin {
    let vertex: Point
    let ax: Int64, ay: Int64, bx: Int64, by: Int64
    let aSquared: Int64, bSquared: Int64
    let lowerBand: Bool
    let bevel: (x: Int64, y: Int64, offset: Double)?

    init?(incoming: StyledDiagonalSpan, outgoing: StyledDiagonalSpan, vertex: Point,
          idempotent: Bool) {
        ax = incoming.dx; ay = incoming.dy; bx = outgoing.dx; by = outgoing.dy
        let turn = ax * by - ay * bx
        guard turn != 0 else { return nil }
        // The width-one software path omits joins that its segment rectangles
        // already cover for destination-idempotent raster operations.
        if idempotent, bx > 0 || (bx == 0 && by > 0) || ax < 0 || (ax == 0 && ay < 0) { return nil }
        self.vertex = vertex
        aSquared = incoming.squaredLength; bSquared = outgoing.squaredLength
        lowerBand = turn > 0
        let dot = Double(ax * bx + ay * by) / (incoming.length * outgoing.length)
        if 2 / max(0, 1 + dot) > 108.856472512142 {
            let side = lowerBand ? -0.5 : 0.5
            let a = (x: -Double(ay) / incoming.length * side, y: Double(ax) / incoming.length * side)
            let b = (x: -Double(by) / outgoing.length * side, y: Double(bx) / outgoing.length * side)
            let vx = b.x - a.x, vy = b.y - a.y
            let scale = max(abs(vx), abs(vy))
            let ex = Int64(vx * 65_536 / scale), ey = Int64(vy * 65_536 / scale)
            bevel = (ex, ey, ((a.x + b.x) * Double(ey) - (a.y + b.y) * Double(ex)) / 2)
        } else { bevel = nil }
    }

    func contains(x: Int, y: Int) -> Bool {
        let px = Int64(x) - Int64(vertex.x), py = Int64(y) - Int64(vertex.y)
        let aDot = px * ax + py * ay, bDot = px * bx + py * by
        guard aDot > 0 || (aDot == 0 && (ax > 0 || (ax == 0 && ay > 0))),
              bDot < 0 || (bDot == 0 && (bx < 0 || (bx == 0 && by < 0))) else { return false }
        func band(_ cross: Int64, _ squared: Int64, _ dx: Int64, _ dy: Int64) -> Bool {
            let outside = lowerBand ? cross < 0 : cross > 0
            if !outside { return true }
            let magnitude = Int128(cross) * Int128(cross) * 4
            if magnitude < Int128(squared) { return true }
            if magnitude > Int128(squared) { return false }
            return lowerBand ? dy < 0 || (dy == 0 && dx > 0) : dy > 0 || (dy == 0 && dx < 0)
        }
        guard band(-px * ay + py * ax, aSquared, ax, ay),
              band(-px * by + py * bx, bSquared, bx, by) else { return false }
        if let bevel {
            let value = Double(px * bevel.y - py * bevel.x)
            let upper = bevel.offset > 0
            if value == bevel.offset {
                // Outward normal for x*ey-y*ex <= offset, reversed for >=.
                return upper ? bevel.y < 0 || (bevel.y == 0 && bevel.x > 0) :
                    bevel.y > 0 || (bevel.y == 0 && bevel.x < 0)
            }
            return upper ? value < bevel.offset : value > bevel.offset
        }
        return true
    }
}
