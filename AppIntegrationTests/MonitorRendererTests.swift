import AppKit
import Testing
@testable import SpiceClient

@MainActor
struct MonitorRendererTests {
    @Test func fullSurfaceAndCropUseTheirOwnAspectRatio() throws {
        let renderer = try MetalRenderer()
        renderer.createSurface(width: 2000, height: 1000)
        #expect(renderer.presentationSize == CGSize(width: 2000, height: 1000))
        #expect(renderer.surfaceFrame(in: CGSize(width: 1000, height: 1000)) ==
                CGRect(x: 0, y: 250, width: 1000, height: 500))
        renderer.sourceRect = CGRect(x: 1000, y: 0, width: 1000, height: 1000)
        #expect(renderer.presentationSize == CGSize(width: 1000, height: 1000))
        #expect(renderer.surfaceFrame(in: CGSize(width: 1000, height: 1000)) ==
                CGRect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(renderer.surfaceSize.width == 2000 && renderer.surfaceSize.height == 1000)
    }

    @Test func partialCropIsClampedAndInvalidCropsPresentBlank() throws {
        let renderer = try MetalRenderer()
        renderer.createSurface(width: 200, height: 100)
        renderer.sourceRect = CGRect(x: -50, y: 25, width: 100, height: 200)
        #expect(renderer.resolvedSourceRect == CGRect(x: 0, y: 25, width: 50, height: 75))
        for rect in [CGRect.zero, CGRect(x: 200, y: 0, width: 10, height: 10),
                     CGRect(x: 0, y: 0, width: -1, height: 10),
                     CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
                     CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)] {
            renderer.sourceRect = rect
            #expect(renderer.resolvedSourceRect == nil)
            #expect(renderer.presentationSize == .zero)
            #expect(renderer.surfaceFrame(in: CGSize(width: 500, height: 500)) == .zero)
        }
        renderer.sourceRect = nil
        #expect(renderer.resolvedSourceRect == CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(renderer.surfaceFrame(in: CGSize(width: CGFloat.nan, height: 500)) == .zero)
    }

    @Test func headsAdoptOneUploadTextureAndPreserveTheirCrop() throws {
        let owner = try MetalRenderer(), head = try MetalRenderer()
        owner.createSurface(width: 200, height: 100)
        head.sourceRect = CGRect(x: 100, y: 0, width: 100, height: 100)
        head.adoptSurface(from: owner)
        #expect(head.surfaceTexture === owner.surfaceTexture)
        #expect(head.surfaceSize.width == 200 && head.presentationSize.width == 100)
        let previous = try #require(head.surfaceTexture)
        owner.createSurface(width: 400, height: 100)
        head.adoptSurface(from: owner)
        #expect(head.surfaceTexture === owner.surfaceTexture)
        #expect(head.surfaceTexture !== previous)
        #expect(head.sourceRect == CGRect(x: 100, y: 0, width: 100, height: 100))
        owner.destroySurface()
        head.adoptSurface(from: owner)
        #expect(head.surfaceTexture == nil && head.presentationSize == .zero)
    }
}
