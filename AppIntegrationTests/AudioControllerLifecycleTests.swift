import Foundation
import Testing
import SpiceKit
@testable import SpiceClient

@MainActor
struct AudioControllerLifecycleTests {
    @Test func lateMicrophonePermissionCannotReactivateAStoppedSession() async throws {
        let gate = PermissionGate()
        let controller = AudioController(session: SpiceSession(profile: ConnectionProfile(host: "audio.example.invalid")),
                                         settings: AppSettings(persistChanges: false),
                                         requestMicrophonePermission: { await gate.request() })
        controller.toggleMicrophone()
        let request = try #require(controller.microphonePermissionTask)
        try await waitForPermission(gate)
        controller.stop()
        await gate.resolve(true)
        await request.value
        #expect(!controller.microphoneEnabled && !controller.guestWantsMicrophone && !controller.hasPlayback)
        #expect(controller.errorMessage == nil)
    }

    @Test func acceptedPermissionIsClearedBySessionStopWithoutCapturingAudio() async throws {
        let controller = AudioController(session: SpiceSession(profile: ConnectionProfile(host: "audio.example.invalid")),
                                         settings: AppSettings(persistChanges: false),
                                         requestMicrophonePermission: { true })
        controller.toggleMicrophone()
        let request = try #require(controller.microphonePermissionTask)
        await request.value
        #expect(controller.microphoneEnabled && !controller.guestWantsMicrophone)
        controller.stop()
        #expect(!controller.microphoneEnabled && controller.microphonePermissionTask == nil)
    }

    private func waitForPermission(_ gate: PermissionGate) async throws {
        for _ in 0..<10_000 {
            if await gate.isWaiting { return }
            await Task.yield()
        }
        Issue.record("Permission request did not reach the controlled callback")
        throw WaitError.timeout
    }
    private enum WaitError: Error { case timeout }
    private actor PermissionGate {
        private var waiter: CheckedContinuation<Bool, Never>?
        var isWaiting: Bool { waiter != nil }
        func request() async -> Bool { await withCheckedContinuation { waiter = $0 } }
        func resolve(_ allowed: Bool) { waiter?.resume(returning: allowed); waiter = nil }
    }
}
