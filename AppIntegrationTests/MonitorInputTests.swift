import AppKit
import Testing
@testable import SpiceClient

@MainActor
struct MonitorInputTests {
    @Test func croppedHeadUsesLocalCoordinatesAtRetinaAndScaledSizes() throws {
        let renderer = try MetalRenderer()
        renderer.createSurface(width: 2000, height: 1000)
        renderer.sourceRect = CGRect(x: 1000, y: 0, width: 1000, height: 1000)
        let view = RemoteDisplayView(renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.stop(); window.close() }
        // Aspect fit leaves 100-point letterboxes on the left/right.
        let center = try #require(view.guestPoint(for: NSPoint(x: 200, y: 100)))
        #expect(center.x == 500 && center.y == 500)
        let topLeft = try #require(view.guestPoint(for: NSPoint(x: 100, y: 0)))
        #expect(topLeft.x == 0 && topLeft.y == 0)
        let clamped = try #require(view.guestPoint(for: NSPoint(x: 400, y: 200)))
        #expect(clamped.x == 999 && clamped.y == 999)
        renderer.sourceRect = .zero
        #expect(view.guestPoint(for: .zero) == nil)
    }

    @Test func emptyViewAndNonfiniteInputDoNotConvertToIntegerCoordinates() throws {
        let renderer = try MetalRenderer()
        renderer.createSurface(width: 10, height: 10)
        let view = RemoteDisplayView(renderer: renderer)
        #expect(view.guestPoint(for: .zero) == nil)
        #expect(view.guestPoint(for: NSPoint(x: CGFloat.nan, y: 0)) == nil)
        view.stop()
    }
}
