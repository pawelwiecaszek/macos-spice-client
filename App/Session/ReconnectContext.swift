/// Carried from a dropped session to the one that replaces it in the same window.
struct ReconnectContext {
    var attempt: Int
    var automatic = false
    var carryOver: SessionCarryOver
    /// Why the original session dropped (shown if reconnecting is cancelled).
    var lastFailure: String?
}

