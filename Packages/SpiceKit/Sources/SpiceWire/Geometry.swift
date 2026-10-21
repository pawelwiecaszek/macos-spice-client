/// `SpicePoint` (spice.proto `Point`): two int32.
public struct Point: Sendable, Hashable {
    public var x: Int32
    public var y: Int32

    public init(x: Int32, y: Int32) {
        self.x = x
        self.y = y
    }

    static func decode(_ reader: inout ByteReader) throws(WireError) -> Point {
        Point(x: try reader.readI32(), y: try reader.readI32())
    }
}

/// `SpicePoint16` (spice.proto `Point16`).
public struct Point16: Sendable, Hashable {
    public var x: Int16
    public var y: Int16

    public init(x: Int16, y: Int16) {
        self.x = x
        self.y = y
    }

    static func decode(_ reader: inout ByteReader) throws(WireError) -> Point16 {
        Point16(x: try reader.readI16(), y: try reader.readI16())
    }
}

/// `SpiceRect` (spice.proto `Rect`): wire order is top, left, bottom, right.
/// `right`/`bottom` are exclusive.
public struct Rect: Sendable, Hashable, CustomStringConvertible {
    public var left: Int32
    public var top: Int32
    public var right: Int32
    public var bottom: Int32

    public init(left: Int32, top: Int32, right: Int32, bottom: Int32) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public init(x: Int, y: Int, width: Int, height: Int) {
        left = Int32(clamping: x)
        top = Int32(clamping: y)
        right = Int32(clamping: x + width)
        bottom = Int32(clamping: y + height)
    }

    public var width: Int { max(0, Int(right) - Int(left)) }
    public var height: Int { max(0, Int(bottom) - Int(top)) }
    public var isEmpty: Bool { right <= left || bottom <= top }

    public func intersection(_ other: Rect) -> Rect {
        let result = Rect(
            left: max(left, other.left), top: max(top, other.top),
            right: min(right, other.right), bottom: min(bottom, other.bottom)
        )
        return result.isEmpty ? Rect(left: 0, top: 0, right: 0, bottom: 0) : result
    }

    /// Smallest rect containing both (an empty rect is the identity).
    public func union(_ other: Rect) -> Rect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return Rect(
            left: min(left, other.left), top: min(top, other.top),
            right: max(right, other.right), bottom: max(bottom, other.bottom)
        )
    }

    public func offsetBy(dx: Int32, dy: Int32) -> Rect {
        Rect(left: left &+ dx, top: top &+ dy, right: right &+ dx, bottom: bottom &+ dy)
    }

    public var description: String { "(\(left),\(top) \(width)x\(height))" }

    static func decode(_ reader: inout ByteReader) throws(WireError) -> Rect {
        let top = try reader.readI32()
        let left = try reader.readI32()
        let bottom = try reader.readI32()
        let right = try reader.readI32()
        return Rect(left: left, top: top, right: right, bottom: bottom)
    }
}

/// `SpiceClip`.
public enum Clip: Sendable, Hashable {
    case none
    case rects([Rect])

    /// Hostile servers could claim billions of rects.
    static let maxRects: UInt32 = 65_536

    static func decode(_ reader: inout ByteReader) throws(WireError) -> Clip {
        let type = try reader.readU8()
        switch type {
        case 0:
            return .none
        case 1:
            let count = try reader.readU32()
            guard count <= maxRects, Int(count) * 16 <= reader.remaining else {
                throw .limitExceeded("clip rects: \(count)")
            }
            var rects: [Rect] = []
            rects.reserveCapacity(Int(count))
            for _ in 0..<count { rects.append(try Rect.decode(&reader)) }
            return .rects(rects)
        default:
            throw .invalidValue("clip type \(type)")
        }
    }
}
