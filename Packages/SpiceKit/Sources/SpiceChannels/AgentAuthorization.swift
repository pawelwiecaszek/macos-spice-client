import Synchronization

/// In-memory lifecycle observations. They grant no server permission; a wire
/// owner accepts only observations issued by its own source.
public final class AgentAuthorizationSource: Sendable {
    private let revision = Mutex<UInt64>(0)
    public init() {}
    public var current: AgentAuthorization { revision.withLock { AgentAuthorization(owner: self, revision: $0) } }
    public func advance() { revision.withLock { $0 &+= 1 } }
    fileprivate func matches(_ value: UInt64) -> Bool { revision.withLock { $0 == value } }
}

public struct AgentAuthorization: Sendable, Equatable {
    private let owner: AgentAuthorizationSource
    private let revision: UInt64
    fileprivate init(owner: AgentAuthorizationSource, revision: UInt64) { self.owner = owner; self.revision = revision }
    public var isCurrent: Bool { owner.matches(revision) }
    func belongs(to source: AgentAuthorizationSource) -> Bool { owner === source }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.owner === rhs.owner && lhs.revision == rhs.revision }
}
