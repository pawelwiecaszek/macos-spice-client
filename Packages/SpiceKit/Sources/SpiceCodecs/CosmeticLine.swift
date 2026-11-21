import SpiceWire

/// Integer cosmetic-line geometry. Direct sampling skips arbitrarily distant offscreen
/// pixels without changing the rasterization phase or including the final endpoint.
struct CosmeticLine {
    let start: Point
    let xStep: Int
    let yStep: Int
    let xMajor: Bool
    let major: Int
    let minor: Int

    init(from start: Point, to end: Point) {
        self.start = start
        let dx = Int(end.x) - Int(start.x), dy = Int(end.y) - Int(start.y)
        xStep = dx < 0 ? -1 : 1; yStep = dy < 0 ? -1 : 1
        xMajor = abs(dx) > abs(dy)
        major = max(abs(dx), abs(dy)); minor = min(abs(dx), abs(dy))
    }

    func visibleSteps(in region: Rect) -> Range<Int> {
        guard major > 0, !region.isEmpty else { return 0..<0 }
        let coordinate = Int(xMajor ? start.x : start.y)
        let lower = Int(xMajor ? region.left : region.top)
        let upper = Int(xMajor ? region.right : region.bottom) - 1
        let step = xMajor ? xStep : yStep
        let first = max(0, step > 0 ? lower - coordinate : coordinate - upper)
        let last = min(major - 1, step > 0 ? upper - coordinate : coordinate - lower)
        return last >= first ? first..<(last + 1) : 0..<0
    }

    func point(at index: Int) -> (x: Int, y: Int) {
        // Tie preference is directional: a decreasing major axis prefers the axial
        // pixel, matching the reference cosmetic line octants without iterative state.
        let bias = (xMajor ? xStep : yStep) < 0 ? 1 : 0
        let offset = (2 * minor * index + major - bias) / (2 * major)
        return xMajor
            ? (Int(start.x) + xStep * index, Int(start.y) + yStep * offset)
            : (Int(start.x) + xStep * offset, Int(start.y) + yStep * index)
    }
}
