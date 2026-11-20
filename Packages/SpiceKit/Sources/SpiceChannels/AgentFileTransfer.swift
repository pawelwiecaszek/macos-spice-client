import Foundation
import SpiceAgent
import SpiceWire

/// Identifies the wire-owned agent lifecycle that accepted a file transfer.
public struct AgentFileTransferAuthorization: Sendable { let epoch: UUID }
public enum AgentFileTransferAdmissionError: Error, Sendable { case unavailable, disabledByGuest, queueFull, invalidMessage }
struct QueuedAgentFileMessage {
    let id: UInt32
    let epoch: UUID
    let chunks: [[UInt8]]
    let cleanup: Bool
    var byteCount: Int { chunks.reduce(0) { $0 + $1.count } }
}
