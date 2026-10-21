#if canImport(os)
import os
#endif

/// Thin wrapper over `os.Logger` (one category per channel) that also builds on Linux.
///
/// Messages passed to `info`/`debug`/`error` must not contain tickets or host names —
/// they are logged as public. Use `sensitive(_:)` for anything identifying a host.
public struct ChannelLogger: Sendable {
    public static let subsystem = "com.pawelwiecaszek.spiceclient"

    #if canImport(os)
    private let logger: Logger
    #endif

    public init(category: String) {
        #if canImport(os)
        logger = Logger(subsystem: Self.subsystem, category: category)
        #endif
    }

    public func debug(_ message: @autoclosure () -> String) {
        #if canImport(os)
        let text = message()
        logger.debug("\(text, privacy: .public)")
        #endif
    }

    public func info(_ message: @autoclosure () -> String) {
        #if canImport(os)
        let text = message()
        logger.info("\(text, privacy: .public)")
        #endif
    }

    public func error(_ message: @autoclosure () -> String) {
        #if canImport(os)
        let text = message()
        logger.error("\(text, privacy: .public)")
        #endif
    }

    /// Makes server-supplied text safe to log: control characters become spaces and the
    /// result is truncated. Still pass it through `sensitive(_:_:)` (it may name hosts).
    public static func sanitize(_ text: String, limit: Int = 200) -> String {
        var cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map {
            $0.properties.generalCategory == .control || $0.properties.generalCategory == .format ? " " : $0
        }))
        if cleaned.count > limit { cleaned = String(cleaned.prefix(limit)) + "…" }
        return cleaned
    }

    /// Logs host-identifying data with `.private` privacy.
    public func sensitive(_ prefix: String, _ value: String) {
        #if canImport(os)
        logger.info("\(prefix, privacy: .public) \(value, privacy: .private)")
        #endif
    }
}
