import Testing
@testable import SpiceClient

struct RavadaPortalLaunchGateTests {
    @Test func manualViewConsumesTheDelayedAutomaticOffer() {
        var gate = RavadaPortalLaunchGate()
        gate.beganDocument()
        let manual = gate.accept(isUserInitiated: true)
        let backgroundStatusUpdate = gate.accept(isUserInitiated: false)
        let anotherExplicitView = gate.accept(isUserInitiated: true)
        #expect(manual)
        #expect(!backgroundStatusUpdate)
        #expect(anotherExplicitView)
    }

    @Test func startCanAutoLaunchOnceWithoutAllowingRepeatedBackgroundDownloads() {
        var gate = RavadaPortalLaunchGate()
        gate.beganDocument()
        let initial = gate.accept(isUserInitiated: false)
        let repeated = gate.accept(isUserInitiated: false)
        #expect(initial)
        #expect(!repeated)
        gate.beganDocument()
        let differentDesktopPage = gate.accept(isUserInitiated: false)
        #expect(differentDesktopPage)
    }

    @Test func stopInvalidatesAPendingAutomaticOffer() {
        var gate = RavadaPortalLaunchGate()
        gate.beganDocument()
        gate.invalidate()
        let late = gate.accept(isUserInitiated: false)
        #expect(!late)
    }
}
