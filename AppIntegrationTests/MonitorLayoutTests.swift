import AppKit
import Metal
import QuartzCore
import SpiceKit
import Testing
@testable import SpiceClient

@MainActor
struct MonitorLayoutTests {
    @Test func multiHeadGeometrySortsIDsAndKeepsSurfaceCropSeparateFromInputID() {
        let layout = MonitorLayout(channel: 0, surface: 7, width: 12, height: 8,
            advertised: [head(9, surface: 7, x: 8, y: 2), head(2, surface: 7, x: 1, y: 1)])
        #expect(!layout.usesFallback)
        #expect(layout.heads.map(\.id) == [2, 9])
        #expect(layout.heads.map(\.inputID) == [2, 9])
        #expect(layout.heads.map(\.crop) == [CGRect(x: 1, y: 1, width: 4, height: 4),
                                          CGRect(x: 8, y: 2, width: 4, height: 4)])
    }

    @Test func singleHeadUsesLocalSurfaceOriginAndSeparateDisplayChannelsUseChannelInputID() {
        let advertised = [head(0, x: 1920, y: 1080)]
        let layout = MonitorLayout(channel: 2, surface: 0, width: 4, height: 4, advertised: advertised)
        #expect(!layout.usesFallback && layout.heads.count == 1)
        #expect(layout.heads.first?.inputID == 2)
        #expect(layout.heads.first?.crop == CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    @Test func disabledHeadsDoNotCreatePresentationRegions() {
        let disabled = [head(0, width: 0), head(1, height: 0)]
        let layout = MonitorLayout(channel: 0, surface: 0, width: 8, height: 4, advertised: disabled)
        #expect(layout.heads.isEmpty && !layout.usesFallback)
        #expect(MonitorLayout(channel: 0, surface: 0, width: 0, height: 4, advertised: nil).heads.isEmpty)
    }

    @Test func unknownOrUnsupportedLayoutsUseOneBoundedWholeSurfaceRegion() {
        let invalidLayouts: [[MonitorHead]?] = [
            nil,
            [head(0), head(0, x: 4)],
            [head(0), head(256, x: 4)],
            [head(0), head(1, surface: 5, x: 4)],
            [head(0), head(1, x: .max)],
            [head(0), head(1, width: 16_385)],
            (0..<5).map { head(UInt32($0), width: 1, x: UInt32($0)) },
        ]
        for advertised in invalidLayouts {
            let layout = MonitorLayout(channel: 0, surface: 0, width: 8, height: 4, advertised: advertised)
            #expect(layout.usesFallback && layout.heads.count == 1)
            #expect(layout.heads.first?.crop == nil && layout.heads.first?.size == CGSize(width: 8, height: 4))
        }
        let extraChannel = MonitorLayout(channel: 1, surface: 0, width: 8, height: 4,
                                         advertised: [head(0), head(1, x: 4)])
        #expect(extraChannel.usesFallback && extraChannel.heads.first?.inputID == 1)
    }

    @Test func headWindowsShareOneUploadTextureAndPointerCoordinatesRemainHeadLocal() throws {
        let controller = makeController()
        defer { controller.stop() }
        let primary = try #require(controller.displayView)
        let displays = try #require(controller.displays)
        controller.handle(.primarySurfaceCreated(surfaceID: 7, width: 8, height: 4))
        controller.handle(.monitorsConfig([head(0, surface: 7), head(1, surface: 7, x: 4)]))
        let secondary = try #require(displays.windows[.init(channel: 0, head: 1)])
        let texture = try #require(primary.renderer.surfaceTexture)
        #expect(secondary.view.renderer.surfaceTexture === texture)
        #expect(primary.renderer.sourceRect == CGRect(x: 0, y: 0, width: 4, height: 4))
        #expect(secondary.view.renderer.sourceRect == CGRect(x: 4, y: 0, width: 4, height: 4))
        #expect(primary.displayID == 0 && secondary.view.displayID == 1)

        // A nonzero surface update is uploaded into the shared owner texture.
        controller.handle(.update(SurfaceUpdate(surfaceID: 7, rect: Rect(x: 5, y: 1, width: 1, height: 1),
                                               pixels: [0xFF12_3456])))
        var pixel: UInt32 = 0
        withUnsafeMutableBytes(of: &pixel) {
            if let base = $0.baseAddress {
                texture.getBytes(base, bytesPerRow: 4, from: MTLRegionMake2D(5, 1, 1, 1), mipmapLevel: 0)
            }
        }
        #expect(pixel == 0xFF12_3456)
        #expect(secondary.view.renderer.surfaceTexture === texture)

        let layer = try #require(secondary.view.layer as? CAMetalLayer)
        layer.contentsScale = 2
        layer.drawableSize = CGSize(width: 16, height: 8) // Letterbox the square head.
        let point = try #require(secondary.view.guestPoint(for: CGPoint(x: 4, y: 2)))
        #expect(point.x == 2 && point.y == 2, "Surface crop offset must not be added to head-local input")
        let edge = try #require(secondary.view.guestPoint(for: CGPoint(x: 8, y: 4)))
        #expect(edge.x == 3 && edge.y == 3)
    }

    @Test func unplugClosesOnlyTheRemovedHeadAndRetainsPrimaryIdentity() throws {
        let controller = makeController()
        defer { controller.stop() }
        let primary = try #require(controller.displayView)
        let displays = try #require(controller.displays)
        controller.handle(.primarySurfaceCreated(surfaceID: 0, width: 8, height: 4))
        controller.handle(.monitorsConfig([head(0), head(1, x: 4)]))
        let secondary = try #require(displays.windows[.init(channel: 0, head: 1)])
        #expect(secondary.window.isVisible)
        controller.handle(.monitorsConfig([head(0)]))
        #expect(displays.windows.isEmpty && !secondary.window.isVisible)
        #expect(controller.displayView === primary && primary.displayID == 0)
        #expect(primary.renderer.presentationSize == CGSize(width: 4, height: 4))
    }

    @Test func configurationBeforeSurfaceCreationIsRetainedAndDisabledConfigurationBlanksViews() throws {
        let controller = makeController()
        defer { controller.stop() }
        let primary = try #require(controller.displayView)
        let displays = try #require(controller.displays)
        controller.handle(.monitorsConfig([head(0), head(1, x: 4)]))
        #expect(displays.windows.isEmpty)
        controller.handle(.primarySurfaceCreated(surfaceID: 0, width: 8, height: 4))
        #expect(displays.windows.count == 1)
        controller.handle(.monitorsConfig([head(0, width: 0), head(1, height: 0)]))
        #expect(displays.windows.isEmpty)
        #expect(primary.renderer.resolvedSourceRect == nil && primary.renderer.presentationSize == .zero)
        #expect(primary.guestPoint(for: .zero) == nil)
    }

    @Test func destroyedSurfacesAndStoppedCoordinatorsRejectLateHandoffs() throws {
        let controller = makeController()
        defer { controller.stop() }
        let primary = try #require(controller.displayView)
        let displays = try #require(controller.displays)
        controller.handle(.primarySurfaceCreated(surfaceID: 7, width: 8, height: 4))
        controller.handle(.monitorsConfig([head(0, surface: 7), head(1, surface: 7, x: 4)]))
        let secondary = try #require(displays.windows[.init(channel: 0, head: 1)])
        controller.handle(.primarySurfaceDestroyed(surfaceID: 7))
        controller.handle(.update(SurfaceUpdate(surfaceID: 7, rect: Rect(x: 0, y: 0, width: 1, height: 1), pixels: [1])))
        controller.handle(.monitorsConfig([head(0, surface: 7), head(1, surface: 7, x: 4)]))
        #expect(primary.renderer.surfaceTexture == nil && displays.windows.isEmpty && !secondary.window.isVisible)
        displays.stop()
        controller.handle(.primarySurfaceCreated(surfaceID: 8, width: 8, height: 4))
        #expect(primary.renderer.surfaceTexture == nil && displays.windows.isEmpty)
    }

    @Test func unsupportedMetadataFallsBackWithoutExtraWindowsAndSecondaryChannelsStayIndependent() throws {
        let controller = makeController()
        defer { controller.stop() }
        let primary = try #require(controller.displayView)
        let displays = try #require(controller.displays)
        controller.handle(.primarySurfaceCreated(surfaceID: 0, width: 8, height: 4))
        controller.handle(.monitorsConfig([head(0), head(1, surface: 9, x: 4)]))
        #expect(displays.windows.isEmpty && primary.renderer.sourceRect == nil)
        #expect(!primary.acceptsGuestInput)
        #expect(controller.displayNotice != nil)
        #expect(primary.renderer.presentationSize == CGSize(width: 8, height: 4))
        displays.handle(.monitorsConfig([head(0, x: 1920)]), channel: 1)
        displays.handle(.primarySurfaceCreated(surfaceID: 0, width: 4, height: 4), channel: 1)
        let secondary = try #require(displays.windows[.init(channel: 1, head: 0)])
        #expect(secondary.view.displayID == 1)
        #expect(secondary.view.renderer.surfaceTexture !== primary.renderer.surfaceTexture)
        #expect(secondary.view.renderer.sourceRect == CGRect(x: 0, y: 0, width: 4, height: 4))
        // A hidden/closed channel must not disappear from a whole-set resize.
        // The primary invalid layout already blocks resize; restore its legacy
        // single-head mapping before checking the closed secondary case.
        controller.handle(.monitorsConfig([head(0, width: 8)]))
        secondary.window.close()
        displays.handle(.primarySurfaceDestroyed(surfaceID: 0), channel: 1)
        #expect(displays.windows.isEmpty && primary.renderer.surfaceTexture != nil)
    }

    @Test func closingAndReofferingAHeadCreatesANewRenderingView() throws {
        let controller = makeController()
        defer { controller.stop() }
        let displays = try #require(controller.displays)
        controller.handle(.primarySurfaceCreated(surfaceID: 0, width: 8, height: 4))
        let heads = [head(0), head(1, x: 4)]
        controller.handle(.monitorsConfig(heads))
        let old = try #require(displays.windows[.init(channel: 0, head: 1)])
        old.window.close()
        #expect(old.wasClosed)
        controller.handle(.monitorsConfig(heads))
        let replacement = try #require(displays.windows[.init(channel: 0, head: 1)])
        #expect(replacement !== old && replacement.view !== old.view)
        #expect(replacement.window.isVisible && !replacement.wasClosed)
    }

    @Test func ambiguousMixedChannelIDsBlockOnlyAmbiguousInput() throws {
        let controller = makeController()
        defer { controller.stop() }
        let displays = try #require(controller.displays)
        controller.handle(.primarySurfaceCreated(surfaceID: 0, width: 8, height: 4))
        controller.handle(.monitorsConfig([head(0), head(1, x: 4)]))
        displays.handle(.primarySurfaceCreated(surfaceID: 0, width: 4, height: 4), channel: 1)
        let shared = try #require(displays.windows[.init(channel: 0, head: 1)])
        let separate = try #require(displays.windows[.init(channel: 1, head: 0)])
        #expect(!shared.view.acceptsGuestInput && !separate.view.acceptsGuestInput)
        #expect(controller.displayView?.acceptsGuestInput == true)
        #expect(controller.displayNotice != nil)
        displays.handle(.primarySurfaceDestroyed(surfaceID: 0), channel: 1)
        #expect(shared.view.acceptsGuestInput && controller.displayNotice == nil)
    }

    private func makeController() -> SessionController {
        let settings = AppSettings(persistChanges: false)
        settings.resizeGuestWithWindow = false
        return SessionController(profile: ConnectionProfile(host: "display.example.invalid"), settings: settings)
    }

    private func head(_ id: UInt32, surface: UInt32 = 0, width: UInt32 = 4, height: UInt32 = 4,
                      x: UInt32 = 0, y: UInt32 = 0) -> MonitorHead {
        MonitorHead(monitorID: id, surfaceID: surface, width: width, height: height, x: x, y: y, flags: 0)
    }
}
