import AppKit
import SpiceKit
import Testing
@testable import SpiceClient

@MainActor
struct MonitorResizeTests {
    @Test func wholeSetResizePreservesClosedHeadsAndMovesTheirOrigins() throws {
        let controller = makeController()
        defer { controller.stop() }
        let primary = try #require(controller.displayView)
        let displays = try #require(controller.displays)
        displays.setMainAuthorization(MonitorResizeAuthority().advance())
        displays.expectChannels([0])
        displays.setMonitorConfigurationSupport(channel: 0, supported: true)
        controller.handle(.topologyAuthorization(MonitorResizeAuthority().advance()))
        controller.handle(.primarySurfaceCreated(surfaceID: 0, width: 8, height: 4))
        controller.handle(.monitorsConfig([head(0), head(1, x: 4)]))
        let secondary = try #require(displays.windows[.init(channel: 0, head: 1)])
        secondary.window.close()
        let resized = try #require(displays.prepareResize(of: primary, width: 6, height: 4))
        #expect(resized.monitors == [monitor(0, width: 6), monitor(1, x: 6)])
        #expect(displays.prepareResize(of: primary, width: 16_384, height: 4) == nil,
                "A shared-surface request must fit the combined canvas, not just each head")
    }

    @Test func consecutiveWindowEditsMergeUntilTheServerPublishesANewLayout() throws {
        let controller = makeController()
        defer { controller.stop() }
        let primary = try #require(controller.displayView)
        let displays = try #require(controller.displays)
        displays.setMainAuthorization(MonitorResizeAuthority().advance())
        displays.expectChannels([0])
        displays.setMonitorConfigurationSupport(channel: 0, supported: true)
        controller.handle(.topologyAuthorization(MonitorResizeAuthority().advance()))
        controller.handle(.primarySurfaceCreated(surfaceID: 0, width: 8, height: 4))
        controller.handle(.monitorsConfig([head(0), head(1, x: 4)]))
        let secondary = try #require(displays.windows[.init(channel: 0, head: 1)])
        #expect(displays.prepareResize(of: primary, width: 6, height: 4) != nil)
        let merged = try #require(displays.prepareResize(of: secondary.view, width: 4, height: 6))
        #expect(merged.monitors == [monitor(0, width: 6), monitor(1, height: 6, x: 6)])
        let revision = displays.resizeRevision
        controller.handle(.monitorsConfig([head(0), head(1, x: 4)]))
        #expect(displays.resizeRevision != revision)
        let fresh = try #require(displays.prepareResize(of: secondary.view, width: 4, height: 6))
        #expect(fresh.monitors == [monitor(0), monitor(1, height: 6, x: 4)])
    }

    @Test func waitsForEveryDeclaredChannelAndKeepsLegacyChannelSlots() throws {
        let controller = makeController()
        defer { controller.stop() }
        let primary = try #require(controller.displayView)
        let displays = try #require(controller.displays)
        controller.handle(.primarySurfaceCreated(surfaceID: 0, width: 4, height: 4))
        #expect(displays.prepareResize(of: primary, width: 6, height: 4) == nil)
        displays.setMainAuthorization(MonitorResizeAuthority().advance())
        displays.expectChannels([0, 1])
        displays.setMonitorConfigurationSupport(channel: 0, supported: false)
        displays.setMonitorConfigurationSupport(channel: 1, supported: false)
        controller.handle(.topologyAuthorization(MonitorResizeAuthority().advance()))
        // Complete the primary metadata pair before testing the missing peer.
        controller.handle(.primarySurfaceCreated(surfaceID: 0, width: 4, height: 4))
        #expect(displays.prepareResize(of: primary, width: 6, height: 4) == nil)
        displays.handle(.topologyAuthorization(MonitorResizeAuthority().advance()), channel: 1)
        displays.handle(.primarySurfaceCreated(surfaceID: 0, width: 4, height: 4), channel: 1)
        #expect(displays.prepareResize(of: primary, width: 6, height: 4)?.monitors ==
                [monitor(0, width: 6), monitor(1, x: 6)])
        displays.setMainAuthorization(MonitorResizeAuthority().advance())
        displays.expectChannels([0, 1, 5])
        #expect(displays.prepareResize(of: primary, width: 6, height: 4) == nil)
    }

    @Test func disabledSparseIdentitySurvivesAndUnsafeMetadataRefusesResize() throws {
        let controller = makeController()
        defer { controller.stop() }
        let primary = try #require(controller.displayView)
        let displays = try #require(controller.displays)
        displays.setMainAuthorization(MonitorResizeAuthority().advance())
        displays.expectChannels([0])
        displays.setMonitorConfigurationSupport(channel: 0, supported: true)
        controller.handle(.topologyAuthorization(MonitorResizeAuthority().advance()))
        controller.handle(.primarySurfaceCreated(surfaceID: 0, width: 8, height: 4))
        controller.handle(.monitorsConfig([head(0), head(1, width: 0, height: 0), head(2, x: 4)]))
        let resized = try #require(displays.prepareResize(of: primary, width: 6, height: 4))
        #expect(resized.monitors == [monitor(0, width: 6), monitor(1, width: 0, height: 0), monitor(2, x: 6)])
        controller.handle(.monitorsConfig([head(0), head(2, x: .max)]))
        #expect(displays.prepareResize(of: primary, width: 6, height: 4) == nil)
        displays.stop()
        #expect(displays.prepareResize(of: primary, width: 6, height: 4) == nil)
    }

    @Test func negotiatedMonitorSupportWaitsForInitialMetadataAndWireAuthorization() throws {
        let controller = makeController()
        defer { controller.stop() }
        let primary = try #require(controller.displayView)
        let displays = try #require(controller.displays)
        let wire = MonitorResizeAuthority()
        displays.setMainAuthorization(MonitorResizeAuthority().advance())
        displays.expectChannels([0])
        displays.setMonitorConfigurationSupport(channel: 0, supported: true)
        controller.handle(.topologyAuthorization(wire.advance()))
        controller.handle(.primarySurfaceCreated(surfaceID: 0, width: 8, height: 4))
        #expect(displays.prepareResize(of: primary, width: 6, height: 4) == nil)
        controller.handle(.topologyAuthorization(wire.advance()))
        #expect(displays.prepareResize(of: primary, width: 6, height: 4) == nil)
        controller.handle(.monitorsConfig([head(0), head(1, x: 4)]))
        #expect(displays.prepareResize(of: primary, width: 6, height: 4) != nil)
        let admitted = try #require(displays.resizeAuthorizations)
        wire.invalidate() // New topology is read before app metadata delivery.
        #expect(!admitted.allSatisfy { $0.isCurrent })
        #expect(displays.prepareResize(of: primary, width: 6, height: 4) == nil)
    }

    private func makeController() -> SessionController {
        let settings = AppSettings(persistChanges: false)
        settings.resizeGuestWithWindow = false
        return SessionController(profile: ConnectionProfile(host: "display.example.invalid"), settings: settings)
    }
    private func head(_ id: UInt32, width: UInt32 = 4, height: UInt32 = 4, x: UInt32 = 0) -> MonitorHead {
        MonitorHead(monitorID: id, surfaceID: 0, width: width, height: height, x: x, y: 0, flags: 0)
    }
    private func monitor(_ id: UInt8, width: UInt32 = 4, height: UInt32 = 4, x: Int32 = 0) -> GuestMonitor {
        GuestMonitor(id: id, width: width, height: height, x: x, y: 0)
    }
}
