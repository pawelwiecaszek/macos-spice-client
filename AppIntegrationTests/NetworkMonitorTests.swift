import AppKit
import Foundation
import Testing
@testable import SpiceClient

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NetworkMonitorTests {
    @Test func onlinePathReturnsWithoutInstallingAWaiter() async {
        let monitor = NetworkMonitor(startMonitoring: false, notificationCenter: NotificationCenter())
        await monitor.waitUntilOnline()
        #expect(monitor.isOnline)
        #expect(monitor.pendingWaitCount == 0)
    }

    @Test func sleepBlocksAUsablePathUntilWake() async throws {
        let center = NotificationCenter()
        let monitor = NetworkMonitor(startMonitoring: false, notificationCenter: center)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await settle { !monitor.isOnline }
        let waiter = Task { await monitor.waitUntilOnline() }
        defer { waiter.cancel() }
        try await settle { monitor.pendingWaitCount == 1 }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await settle { monitor.isOnline && monitor.pendingWaitCount == 0 }
        await waiter.value
    }

    @Test func wakingWhileOfflineKeepsTheWaiterUntilAPathArrives() async throws {
        let center = NotificationCenter()
        let monitor = NetworkMonitor(startMonitoring: false, notificationCenter: center)
        monitor.updatePath(false)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await drainCallbacks()
        let waiter = Task { await monitor.waitUntilOnline() }
        defer { waiter.cancel() }
        try await settle { monitor.pendingWaitCount == 1 }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drainCallbacks()
        #expect(!monitor.isOnline)
        #expect(monitor.pendingWaitCount == 1)
        monitor.updatePath(true)
        try await settle { monitor.isOnline && monitor.pendingWaitCount == 0 }
        await waiter.value
    }

    @Test func pathUpdatesCannotReleaseWaitersWhileAsleep() async throws {
        let center = NotificationCenter()
        let monitor = NetworkMonitor(startMonitoring: false, notificationCenter: center)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await settle { !monitor.isOnline }
        monitor.updatePath(false)
        let waiter = Task { await monitor.waitUntilOnline() }
        defer { waiter.cancel() }
        try await settle { monitor.pendingWaitCount == 1 }
        monitor.updatePath(true)
        #expect(!monitor.isOnline)
        #expect(monitor.pendingWaitCount == 1)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await settle { monitor.isOnline && monitor.pendingWaitCount == 0 }
        await waiter.value
    }

    @Test func cancellationRemovesOnlyItsOwnWaiter() async throws {
        let monitor = NetworkMonitor(startMonitoring: false, notificationCenter: NotificationCenter())
        monitor.updatePath(false)
        let first = Task { await monitor.waitUntilOnline() }
        let second = Task { await monitor.waitUntilOnline() }
        defer { first.cancel(); second.cancel() }
        try await settle { monitor.pendingWaitCount == 2 }
        first.cancel()
        await first.value
        #expect(monitor.pendingWaitCount == 1)
        #expect(!monitor.isOnline)
        monitor.updatePath(true)
        await second.value
        #expect(monitor.pendingWaitCount == 0)
    }

    @Test func repeatedWakeNotificationsDoNotResumeAWaiterTwice() async throws {
        let center = NotificationCenter()
        let monitor = NetworkMonitor(startMonitoring: false, notificationCenter: center)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await settle { !monitor.isOnline }
        let waiter = Task { await monitor.waitUntilOnline() }
        defer { waiter.cancel() }
        try await settle { monitor.pendingWaitCount == 1 }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await waiter.value
        await drainCallbacks()
        #expect(monitor.isOnline)
        #expect(monitor.pendingWaitCount == 0)
    }

    @Test func backToBackSleepAndWakeKeepTheLastAvailabilityState() async {
        let center = NotificationCenter()
        let monitor = NetworkMonitor(startMonitoring: false, notificationCenter: center)
        for _ in 0..<20 {
            center.post(name: NSWorkspace.willSleepNotification, object: nil)
            center.post(name: NSWorkspace.didWakeNotification, object: nil)
        }
        // Enqueue after all notification callbacks to make the ordering assertion deterministic.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(monitor.isOnline)
        #expect(monitor.pendingWaitCount == 0)
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Availability did not reach the expected state")
        throw CancellationError()
    }

    private func drainCallbacks() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
