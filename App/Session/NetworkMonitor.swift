import Foundation
import Network
import Observation

/// Whether the Mac has a usable network path; reconnection waits for one instead of
/// burning attempts while offline (asleep, Wi-Fi off, between networks).
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isOnline = true
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private init() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in NetworkMonitor.shared.update(online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.pawelwiecaszek.spiceclient.network-monitor"))
    }

    private func update(_ online: Bool) {
        isOnline = online
        guard online else { return }
        let ready = waiters.values
        waiters.removeAll()
        for waiter in ready { waiter.resume() }
    }

    /// Returns once the network is available (immediately if it is) or the task is cancelled.
    func waitUntilOnline() async {
        guard !isOnline else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in NetworkMonitor.shared.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}
