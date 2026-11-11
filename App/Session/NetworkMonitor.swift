import AppKit
import Foundation
import Network
import Observation

/// Whether the Mac has a usable network path; reconnection waits for one instead of
/// burning attempts while offline (asleep, Wi-Fi off, between networks).
@MainActor
@Observable
final class NetworkMonitor: NSObject {
    static let shared = NetworkMonitor()

    private(set) var isOnline = true
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var pathIsOnline = true
    @ObservationIgnored private var isAwake = true

    var pendingWaitCount: Int { waiters.count }

    init(startMonitoring: Bool = true, notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        super.init()
        // Workspace power notifications belong to its own center, not .default.
        notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        guard startMonitoring else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async { [weak self] in self?.updatePath(online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.pawelwiecaszek.spiceclient.network-monitor"))
    }

    /// The network-path half of availability, independently injectable in hosted tests.
    func updatePath(_ online: Bool) {
        pathIsOnline = online
        updateAvailability()
    }

    // NotificationCenter delivers selectors on the posting thread. Hop explicitly
    // using the FIFO main queue so a sleep update cannot overtake a later wake.
    @objc nonisolated private func willSleep(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.setAwake(false) }
    }

    @objc nonisolated private func didWake(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.setAwake(true) }
    }

    private func setAwake(_ awake: Bool) {
        isAwake = awake
        updateAvailability()
    }

    private func updateAvailability() {
        isOnline = pathIsOnline && isAwake
        guard isOnline else { return }
        let ready = Array(waiters.values)
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
            Task { @MainActor in self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}
