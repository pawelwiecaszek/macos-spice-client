import Synchronization

/// Per-display topology ownership, invalidated at the wire reader before handing
/// new metadata to the UI. No timers, server IDs or persisted authority are used.
public final class MonitorResizeAuthority: Sendable {
    private let revision = Mutex<UInt64>(0)
    public init() {}

    /// Retires every earlier topology observation and returns its replacement.
    public func advance() -> MonitorResizeAuthorization {
        revision.withLock { value in
            value &+= 1
            return MonitorResizeAuthorization(owner: self, revision: value)
        }
    }

    /// Retires queued requests on close without authorizing a new observation.
    public func invalidate() { revision.withLock { $0 &+= 1 } }
    fileprivate func matches(_ value: UInt64) -> Bool { revision.withLock { $0 == value } }
}

/// An in-memory observation of one display's topology. Complete-set requests must
/// retain an observation for every display and revalidate before first-chunk send.
public struct MonitorResizeAuthorization: Sendable, Equatable {
    private let owner: MonitorResizeAuthority
    private let revision: UInt64
    fileprivate init(owner: MonitorResizeAuthority, revision: UInt64) { self.owner = owner; self.revision = revision }
    public var isCurrent: Bool { owner.matches(revision) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.owner === rhs.owner && lhs.revision == rhs.revision }
}
