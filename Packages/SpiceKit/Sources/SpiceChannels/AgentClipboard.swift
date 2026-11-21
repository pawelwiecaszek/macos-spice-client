import SpiceAgent
import Synchronization

/// Captures both an agent lifecycle and the clipboard negotiation used to decode
/// a delivery. Capability changes cannot authorize an older queued reply.
public struct ClipboardAgentAuthorization: Sendable, Equatable {
    public let agent: AgentAuthorization
    let negotiation: AgentAuthorization
    let ownership: AgentAuthorization?
    public init(agent: AgentAuthorization, negotiation: AgentAuthorization, ownership: AgentAuthorization? = nil) {
        self.agent = agent; self.negotiation = negotiation; self.ownership = ownership
    }
    public var isCurrent: Bool { agent.isCurrent && negotiation.isCurrent && (ownership?.isCurrent ?? true) }
    public func sharesClipboardOwnership(with other: Self) -> Bool { ownership == other.ownership }
}

public struct AgentClipboardDelivery: Sendable {
    public let message: ClipboardMessage
    public let authorization: ClipboardAgentAuthorization
    public init(message: ClipboardMessage, authorization: ClipboardAgentAuthorization) { self.message = message; self.authorization = authorization }
}

/// Local sharing lifetime, revoked by stop, focus loss or changed ownership.
public final class ClipboardSharingAuthority: Sendable {
    private let source = AgentAuthorizationSource()
    public init() {}
    public var current: ClipboardSharingAuthorization { ClipboardSharingAuthorization(observation: source.current) }
    public func requestAuthorization() -> ClipboardSharingAuthorization {
        ClipboardSharingAuthorization(observation: source.current, requestReceipt: ClipboardRequestReceipt())
    }
    public func invalidate() { source.advance() }
}

public struct ClipboardSharingAuthorization: Sendable {
    let observation: AgentAuthorization
    public let requestReceipt: ClipboardRequestReceipt?
    init(observation: AgentAuthorization, requestReceipt: ClipboardRequestReceipt? = nil) {
        self.observation = observation; self.requestReceipt = requestReceipt
    }
    public var isCurrent: Bool { observation.isCurrent }
}

/// Local transmission receipt, not a wire request ID. A proven-unsent request
/// may be cancelled without quarantining a response that cannot exist.
public final class ClipboardRequestReceipt: Sendable {
    public enum Status: Sendable { case queued, committed, discarded }
    private let state = Mutex(Status.queued)
    public var status: Status { state.withLock { $0 } }
    @discardableResult public func tryCommit() -> Bool {
        state.withLock { value in
            guard value == .queued else { return false }
            value = .committed
            return true
        }
    }
    @discardableResult public func cancelIfUnsent() -> Bool {
        state.withLock { value in
            guard value != .committed else { return false }
            value = .discarded
            return true
        }
    }
    func discardBeforeSend() { _ = cancelIfUnsent() }
}

struct ClipboardCommitAuthorization {
    let agent: ClipboardAgentAuthorization
    let sharing: ClipboardSharingAuthorization
    func canBegin(current: ClipboardAgentAuthorization?) -> Bool {
        current == agent && agent.isCurrent && sharing.isCurrent
            && (sharing.requestReceipt == nil || sharing.requestReceipt?.status == .queued)
    }
    func begin(current: ClipboardAgentAuthorization?) -> Bool {
        guard canBegin(current: current) else { return false }
        return sharing.requestReceipt?.tryCommit() ?? true
    }
    func discardUnstarted() { sharing.requestReceipt?.discardBeforeSend() }
}

public enum AgentClipboardAction: Sendable, Equatable {
    case offer([ClipboardDataType])
    case request(ClipboardDataType)
    case provide(ClipboardDataType, [UInt8])
    case release
}

struct QueuedAgentClipboardMessage {
    let action: AgentClipboardAction
    let agent: ClipboardAgentAuthorization
    let sharing: ClipboardSharingAuthorization
    var byteCount: Int {
        if case .provide(let type, let bytes) = action {
            let size = type == .utf8Text ? min(ClipboardCodec.maxDataSize, min(bytes.count, ClipboardCodec.maxDataSize) * 3) : bytes.count
            return size + 64
        }
        return 320
    }
}
