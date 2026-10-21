import Synchronization

/// A one-time SPICE ticket (password) held only in memory.
///
/// The bytes can be wiped once authentication is done. `description` never reveals the
/// value, so accidentally interpolating a ticket into a log message is harmless.
///
/// Wiping is best effort, not a guarantee: this object's buffer and the temporary copies
/// SpiceKit makes while linking (plaintext + NUL, the encryptor's input) are zeroed, but
/// Swift value semantics and Security.framework may hold further transient copies until
/// their memory is reused. The ticket is never written to disk or logs.
public final class SecretTicket: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let storage: Mutex<[UInt8]?>

    public init(_ value: String) {
        storage = Mutex(Array(value.utf8))
    }

    public init(bytes: [UInt8]) {
        storage = Mutex(bytes)
    }

    /// Calls `body` with the ticket bytes, or `nil` after `wipe()`.
    public func withBytes<R>(_ body: ([UInt8]?) throws -> R) rethrows -> R {
        try storage.withLock { try body($0) }
    }

    /// `true` once the ticket has been wiped.
    public var isWiped: Bool { storage.withLock { $0 == nil } }

    /// Overwrites the stored bytes with zeros and drops them.
    public func wipe() {
        storage.withLock { bytes in
            // Zeroes this object's buffer in place. If a copy handed out by `withBytes` is
            // still alive the buffer is shared and copy-on-write zeroes a fresh copy instead;
            // that is why wiping is documented as best effort.
            let count = bytes?.count ?? 0
            for index in 0..<count { bytes?[index] = 0 }
            bytes = nil
        }
    }

    public var description: String { "<ticket redacted>" }
    public var debugDescription: String { "<ticket redacted>" }
}
