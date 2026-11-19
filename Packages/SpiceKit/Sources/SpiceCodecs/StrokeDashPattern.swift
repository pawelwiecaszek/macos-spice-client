import SpiceWire

/// A bounded periodic foreground/gap lookup for the pinned SPICE stroke reference.
/// The renderer supplies distance in rounded pixel units; queries never walk the
/// skipped distance. Rotation and parity intentionally follow the reference even
/// for odd-length lists, rather than inventing an alternating doubled period.
struct StrokeDashPattern: Sendable {
    let period: Int64
    private let boundaries: [Int64]
    private let initialOffset: Int64

    init(attributes: StrokeAttributes) throws(StrokeError) {
        guard attributes.flags & ~UInt8(12) == 0, attributes.isStyled,
              !attributes.style.isEmpty, attributes.style.count <= 255 else {
            throw .invalidPath
        }
        var lengths: [Int64] = []
        lengths.reserveCapacity(attributes.style.count)
        for raw in attributes.style {
            guard raw > 0 else { throw .invalidPath }
            let pixels = (Int64(raw) + 7) >> 4
            // The legacy renderer stores rounded lengths in bytes. Refuse zero
            // or wrapping values instead of reproducing an unsafe byte cast.
            guard (1...255).contains(pixels) else { throw .unsupported }
            lengths.append(pixels)
        }
        if attributes.startsWithGap {
            let first = lengths.removeFirst()
            lengths.append(first)
            initialOffset = lengths[0]
        } else {
            initialOffset = 0
        }
        var total: Int64 = 0
        var ends: [Int64] = []
        ends.reserveCapacity(lengths.count)
        for length in lengths {
            total += length
            ends.append(total)
        }
        period = total // At most 255 lengths, each at most 255 pixels: 65,025.
        boundaries = ends
    }

    /// Foreground at the supplied distance, with positive modular handling for
    /// negative probes too. Reducing first keeps Int64 extremes overflow-safe.
    func isForeground(at distance: Int64) -> Bool {
        state(at: distance).index & 1 == 0
    }

    /// Foreground touching the preceding segment endpoint. The pinned wide-line
    /// reference has a distinct parity rule at exact boundaries of odd style lists.
    func foregroundBeforeEndpoint(at distance: Int64) -> Bool {
        let state = state(at: distance)
        return ((state.index & 1) ^ (state.offset == 0 ? 0 : 1)) != 0
    }

    private func state(at distance: Int64) -> (index: Int, offset: Int64) {
        let remainder = distance % period
        let normalized = remainder < 0 ? remainder + period : remainder
        let phase = (normalized + initialOffset) % period
        var lower = 0, upper = boundaries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if phase < boundaries[middle] { upper = middle }
            else { lower = middle + 1 }
        }
        return (lower, phase - (lower == 0 ? 0 : boundaries[lower - 1]))
    }
}
