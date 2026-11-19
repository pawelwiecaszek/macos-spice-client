/// Signed 28.4 coordinates used by SPICE paths.
public struct StrokePoint: Sendable, Hashable {
    public let x: Int32
    public let y: Int32
    public init(x: Int32, y: Int32) { self.x = x; self.y = y }

    /// Cosmetic strokes round exact half-pixels down, including negative coordinates.
    public var rounded: Point { Point(x: Int32((Int64(x) + 7) >> 4), y: Int32((Int64(y) + 7) >> 4)) }
}

/// Path segment flags in spice-common@58d375e spice.proto:339–345.
public struct StrokeFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let begin = Self(rawValue: 1)
    public static let end = Self(rawValue: 2)
    public static let close = Self(rawValue: 8)
    public static let bezier = Self(rawValue: 16)
}

/// A packed path segment. Bezier points after an optional initial point form cubic triples.
public struct StrokeSegment: Sendable, Hashable {
    public let flags: StrokeFlags
    public let points: [StrokePoint]
    public init(flags: StrokeFlags, points: [StrokePoint]) { self.flags = flags; self.points = points }
}

/// Bounded path decoded from inline variable-length segments, not wire pointer arrays.
public struct StrokePath: Sendable, Hashable {
    public static let maxSegments = 4096
    public static let maxPoints = 65_536
    public let segments: [StrokeSegment]
    public init(segments: [StrokeSegment]) { self.segments = segments }

    /// Checks public-model invariants as well as decoded hostile input.
    public func validate() throws(WireError) {
        guard segments.count <= Self.maxSegments else { throw .limitExceeded("stroke segments") }
        var active = false, total = 0
        for segment in segments {
            guard segment.flags.rawValue & ~UInt8(27) == 0, !segment.points.isEmpty,
                  !segment.flags.contains(.close) || segment.flags.contains(.end) else {
                throw .invalidValue("stroke segment flags or points")
            }
            guard segment.points.count <= Self.maxPoints - total else { throw .limitExceeded("stroke points") }
            total += segment.points.count
            if segment.flags.contains(.begin) { active = true }
            guard active else { throw .invalidValue("stroke path without beginning") }
            let controls = segment.points.count - (segment.flags.contains(.begin) ? 1 : 0)
            if segment.flags.contains(.bezier), controls % 3 != 0 { throw .invalidValue("stroke Bezier points") }
            if segment.flags.contains(.end) { active = false }
        }
    }

    static func decode(_ reader: inout ByteReader) throws(WireError) -> Self {
        let count = Int(try reader.readU32())
        guard count <= maxSegments else { throw .limitExceeded("stroke segments") }
        var segments: [StrokeSegment] = [], total = 0
        for _ in 0..<count {
            let flags = StrokeFlags(rawValue: try reader.readU8())
            let points = Int(try reader.readU32())
            guard points <= maxPoints - total else { throw .limitExceeded("stroke points") }
            guard points * 8 <= reader.remaining else { throw .truncated(needed: points * 8, available: reader.remaining) }
            var values: [StrokePoint] = []
            values.reserveCapacity(points)
            for _ in 0..<points { values.append(StrokePoint(x: try reader.readI32(), y: try reader.readI32())) }
            segments.append(StrokeSegment(flags: flags, points: values)); total += points
        }
        let path = Self(segments: segments)
        try path.validate()
        return path
    }
}

/// Cosmetic stroke attributes. The current wire format has no width, cap or join fields.
public struct StrokeAttributes: Sendable, Hashable {
    public let flags: UInt8
    public let style: [Int32]
    public var isStyled: Bool { flags & 8 != 0 }
    public var startsWithGap: Bool { flags & 4 != 0 }
    public init(flags: UInt8 = 0, style: [Int32] = []) { self.flags = flags; self.style = style }
}

/// `DRAW_STROKE`, spice-common@58d375e spice.proto:501–510,646–657,859–868.
public struct DrawStroke: Sendable, Hashable {
    public let base: DisplayBase
    public let path: StrokePath
    public let attributes: StrokeAttributes
    public let brush: Brush
    public let foreMode: Ropd
    public let backMode: Ropd

    public init(decoding bytes: [UInt8]) throws(WireError) {
        var reader = ByteReader(bytes)
        base = try DisplayBase.decode(&reader)
        let pathPointer = try reader.readU32()
        let flags = try reader.readU8()
        guard flags & ~UInt8(12) == 0, flags & 4 == 0 || flags & 8 != 0 else { throw .invalidValue("stroke line flags") }
        var style: [Int32] = [], stylePointer: UInt32 = 0
        if flags & 8 != 0 {
            let count = Int(try reader.readU8())
            stylePointer = try reader.readU32()
            guard count > 0, stylePointer > 0 else { throw .invalidValue("stroke style") }
            var values = try reader.reader(atPointer: stylePointer)
            for _ in 0..<count { style.append(try values.readI32()) }
            guard style.allSatisfy({ $0 > 0 }) else { throw .invalidValue("stroke style length") }
        }
        attributes = StrokeAttributes(flags: flags, style: style)
        brush = try Brush.decode(&reader)
        foreMode = Ropd(rawValue: try reader.readU16())
        backMode = Ropd(rawValue: try reader.readU16())
        guard pathPointer >= reader.offset, pathPointer != 0,
              stylePointer == 0 || stylePointer >= reader.offset else { throw .invalidValue("stroke data offset") }
        var pathReader = try reader.reader(atPointer: pathPointer)
        path = try StrokePath.decode(&pathReader)
    }
}
