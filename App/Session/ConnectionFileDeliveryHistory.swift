import Foundation

/// Suppresses duplicate browser/Finder/watcher delivery without retaining tickets.
struct ConnectionFileDeliveryHistory {
    private var delivered: [String: ContinuousClock.Instant] = [:]
    private var deletedURLs: [URL: ContinuousClock.Instant] = [:]
    private let lifetime: Duration = .seconds(5)

    mutating func accept(digest: String, at now: ContinuousClock.Instant = .now) -> Bool {
        prune(at: now)
        guard delivered[digest] == nil else { return false }
        delivered[digest] = now
        return true
    }

    mutating func recordDeletion(of url: URL, at now: ContinuousClock.Instant = .now) {
        prune(at: now)
        deletedURLs[url.standardizedFileURL] = now
    }

    mutating func discard(digest: String) {
        delivered.removeValue(forKey: digest)
    }

    mutating func wasJustDeleted(_ url: URL, at now: ContinuousClock.Instant = .now) -> Bool {
        prune(at: now)
        return deletedURLs[url.standardizedFileURL] != nil
    }

    private mutating func prune(at now: ContinuousClock.Instant) {
        delivered = delivered.filter { $0.value.duration(to: now) < lifetime }
        deletedURLs = deletedURLs.filter { $0.value.duration(to: now) < lifetime }
        // Bound even a burst of distinct files; pruning is an optimization, not a security decision.
        if delivered.count >= 256 { delivered.removeAll(keepingCapacity: true) }
        if deletedURLs.count >= 256 { deletedURLs.removeAll(keepingCapacity: true) }
    }
}
