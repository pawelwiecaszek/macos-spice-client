import Foundation
import Observation
import SpiceKit

/// Explicit access check, not a polling catalog or a machine-action controller.
@MainActor
@Observable
final class RavadaCatalogCheck {
    private(set) var isChecking = false
    private(set) var summary: String?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let read: @MainActor () async throws -> RavadaCatalog
    @ObservationIgnored private let cancelRead: @MainActor () -> Void

    init(read: @escaping @MainActor () async throws -> RavadaCatalog,
         cancel: @escaping @MainActor () -> Void) {
        self.read = read
        cancelRead = cancel
    }

    func check() {
        guard !isChecking else { return }
        let current = UUID()
        generation = current
        isChecking = true
        summary = nil
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = try await read()
                guard !Task.isCancelled, generation == current else { return }
                summary = String(localized: "Desktop access confirmed: \(catalog.entries.count) catalog entries available. Continue using the portal to connect.")
            } catch {
                guard !Task.isCancelled, generation == current else { return }
                summary = (error as? RavadaBrokerError ?? .unavailable).localizedDescription
            }
            isChecking = false
            work = nil
        }
    }

    func cancel() {
        generation = UUID()
        work?.cancel()
        work = nil
        cancelRead()
        isChecking = false
        summary = nil
    }
}
