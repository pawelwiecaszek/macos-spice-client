import SpiceWire

/// One guest-agent monitor slot. Both dimensions zero describe a disabled slot.
public struct GuestMonitor: Sendable, Equatable {
    public let id: UInt8
    public let width: UInt32
    public let height: UInt32
    public let x: Int32
    public let y: Int32

    /// Positions are signed guest-desktop pixels; IDs identify agent array slots.
    public init(id: UInt8, width: UInt32, height: UInt32, x: Int32, y: Int32) {
        self.id = id; self.width = width; self.height = height; self.x = x; self.y = y
    }

}

/// A complete, bounded desired monitor set, never a partial resize command.
public struct GuestMonitorLayout: Sendable, Equatable {
    /// Explicit entries sorted by slot ID. Omitted slots encode as disabled.
    public let monitors: [GuestMonitor]

    /// Local safety policy: 16 explicit entries, dimensions at most 16,384 pixels,
    /// total enabled pixels at most one maximum surface, and no overlapping heads.
    public init?(_ monitors: [GuestMonitor]) {
        guard (1...16).contains(monitors.count), Set(monitors.map(\.id)).count == monitors.count else { return nil }
        var enabled: [GuestMonitor] = []
        var pixels: UInt64 = 0
        for monitor in monitors {
            if monitor.width == 0 && monitor.height == 0 { continue }
            guard (1...16_384).contains(monitor.width), (1...16_384).contains(monitor.height),
                  Int64(monitor.x) + Int64(monitor.width) <= Int64(Int32.max),
                  Int64(monitor.y) + Int64(monitor.height) <= Int64(Int32.max) else { return nil }
            pixels += UInt64(monitor.width) * UInt64(monitor.height)
            guard pixels <= 16_384 * 16_384 else { return nil }
            guard !enabled.contains(where: { Self.overlaps($0, monitor) }) else { return nil }
            enabled.append(monitor)
        }
        guard !enabled.isEmpty else { return nil }
        self.monitors = monitors.sorted { $0.id < $1.id }
    }

    /// Resizes an enabled head in place, moving heads at/beyond its old right and
    /// bottom edges by the corresponding delta. Other sizes and gaps are retained.
    /// Invalid, overlapping or overflowing results leave the original set intact.
    public func resizing(id: UInt8, width: UInt32, height: UInt32) -> GuestMonitorLayout? {
        guard let target = monitors.first(where: { $0.id == id }), target.width > 0, target.height > 0,
              (1...16_384).contains(width), (1...16_384).contains(height) else { return nil }
        let right = Int64(target.x) + Int64(target.width)
        let bottom = Int64(target.y) + Int64(target.height)
        let dx = Int64(width) - Int64(target.width), dy = Int64(height) - Int64(target.height)
        var result: [GuestMonitor] = []
        result.reserveCapacity(monitors.count)
        for monitor in monitors {
            if monitor.id == id {
                result.append(GuestMonitor(id: id, width: width, height: height, x: target.x, y: target.y))
            } else if monitor.width > 0 && monitor.height > 0 {
                let x = Int64(monitor.x) + (Int64(monitor.x) >= right ? dx : 0)
                let y = Int64(monitor.y) + (Int64(monitor.y) >= bottom ? dy : 0)
                guard let checkedX = Int32(exactly: x), let checkedY = Int32(exactly: y) else { return nil }
                result.append(GuestMonitor(id: monitor.id, width: monitor.width, height: monitor.height,
                                           x: checkedX, y: checkedY))
            } else { result.append(monitor) }
        }
        return GuestMonitorLayout(result)
    }

    /// Encodes the entire desired set only when peer capabilities preserve its
    /// sparse IDs and positions. Uses the existing vdagent wire serializer.
    public func message(capabilities: CapabilitySet) -> AgentMessage? {
        guard capabilities.contains(AgentCapability.monitorsConfig.rawValue), let last = monitors.last else { return nil }
        let enabled = monitors.filter { $0.width > 0 && $0.height > 0 }
        let sparse = monitors.count != Int(last.id) + 1 || enabled.count != monitors.count
        guard !sparse || capabilities.contains(AgentCapability.sparseMonitorsConfig.rawValue) else { return nil }
        let positioned = enabled.count > 1 || enabled.contains { $0.x != 0 || $0.y != 0 }
        let canPosition = capabilities.contains(AgentCapability.monitorsConfigPosition.rawValue)
        guard !positioned || canPosition else { return nil }
        let entries = Dictionary(uniqueKeysWithValues: monitors.map { ($0.id, $0) })
        let slots = (0...Int(last.id)).map { index -> (width: UInt32, height: UInt32, x: Int32, y: Int32) in
            guard let monitor = entries[UInt8(index)], monitor.width > 0 && monitor.height > 0 else {
                return (0, 0, 0, 0)
            }
            return (monitor.width, monitor.height, monitor.x, monitor.y)
        }
        return AgentMessage.monitorsConfig(slots, usePosition: canPosition)
    }

    private static func overlaps(_ a: GuestMonitor, _ b: GuestMonitor) -> Bool {
        Int64(a.x) < Int64(b.x) + Int64(b.width) && Int64(b.x) < Int64(a.x) + Int64(a.width) &&
        Int64(a.y) < Int64(b.y) + Int64(b.height) && Int64(b.y) < Int64(a.y) + Int64(a.height)
    }
}
