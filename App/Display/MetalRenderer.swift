import Metal
import QuartzCore
import SpiceKit
import os

/// Presents the SPICE primary surface (and the server-mode cursor) into a `CAMetalLayer`.
///
/// The renderer owns one `.bgra8Unorm` texture per presented surface. Updates arrive as
/// `SurfaceUpdate`s (CPU pixels) and are uploaded with `replace(region:)`; drawing happens
/// only when something changed.
@MainActor
final class MetalRenderer {
    struct QuadUniforms {
        var scale: SIMD2<Float>
        var offset: SIMD2<Float>
    }

    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let surfacePipeline: any MTLRenderPipelineState
    private let cursorPipeline: any MTLRenderPipelineState
    private let nearestSampler: any MTLSamplerState
    private let linearSampler: any MTLSamplerState
    private let log = Logger(subsystem: "com.pawelwiecaszek.spiceclient", category: "render")

    private(set) var surfaceTexture: (any MTLTexture)?
    private(set) var surfaceSize: (width: Int, height: Int) = (0, 0)

    private var cursorTexture: (any MTLTexture)?
    private var cursorHotSpot = SIMD2<Float>(0, 0)
    /// Guest cursor position in surface pixels (server mouse mode).
    var cursorPosition = SIMD2<Float>(0, 0) { didSet { needsDisplay = true } }
    var showsCursorOverlay = false { didSet { needsDisplay = true } }

    private(set) var needsDisplay = true

    enum RendererError: Error { case noDevice, pipeline(String) }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RendererError.noDevice
        }
        self.device = device
        self.queue = queue
        queue.label = "SPICE presentation queue"

        guard let library = device.makeDefaultLibrary() else { throw RendererError.pipeline("no default library") }
        func pipeline(fragment: String, blended: Bool, label: String) throws -> any MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = label
            descriptor.vertexFunction = library.makeFunction(name: "quad_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]
            attachment?.pixelFormat = .bgra8Unorm
            if blended {
                attachment?.isBlendingEnabled = true
                attachment?.sourceRGBBlendFactor = .one
                attachment?.sourceAlphaBlendFactor = .one
                attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        surfacePipeline = try pipeline(fragment: "surface_fragment", blended: false, label: "Surface pipeline")
        cursorPipeline = try pipeline(fragment: "cursor_fragment", blended: true, label: "Cursor pipeline")

        func sampler(_ filter: MTLSamplerMinMagFilter, label: String) -> (any MTLSamplerState)? {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = filter
            descriptor.magFilter = filter
            descriptor.sAddressMode = .clampToEdge
            descriptor.tAddressMode = .clampToEdge
            descriptor.label = label
            return device.makeSamplerState(descriptor: descriptor)
        }
        guard let nearest = sampler(.nearest, label: "Nearest sampler"),
              let linear = sampler(.linear, label: "Linear sampler") else {
            throw RendererError.pipeline("sampler")
        }
        nearestSampler = nearest
        linearSampler = linear
    }

    func configure(_ layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        layer.presentsWithTransaction = false
        layer.displaySyncEnabled = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = true
    }

    // MARK: Surface updates

    func createSurface(width: Int, height: Int) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        surfaceTexture = device.makeTexture(descriptor: descriptor)
        surfaceTexture?.label = "Primary surface \(width)x\(height)"
        surfaceSize = (width, height)
        needsDisplay = true
    }

    func destroySurface() {
        surfaceTexture = nil
        surfaceSize = (0, 0)
        needsDisplay = true
    }

    func apply(_ update: SurfaceUpdate) {
        guard let texture = surfaceTexture else { return }
        let rect = update.rect
        guard rect.left >= 0, rect.top >= 0, Int(rect.right) <= texture.width, Int(rect.bottom) <= texture.height,
              update.pixels.count == rect.width * rect.height else { return }
        update.pixels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(Int(rect.left), Int(rect.top), rect.width, rect.height),
                            mipmapLevel: 0, withBytes: base, bytesPerRow: rect.width * 4)
        }
        needsDisplay = true
    }

    func setCursor(_ cursor: CursorImage?) {
        guard let cursor, cursor.image.width > 0, cursor.image.height > 0 else {
            cursorTexture = nil
            needsDisplay = true
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: cursor.image.width, height: cursor.image.height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "Cursor"
        cursor.image.pixels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture?.replace(region: MTLRegionMake2D(0, 0, cursor.image.width, cursor.image.height),
                             mipmapLevel: 0, withBytes: base, bytesPerRow: cursor.image.width * 4)
        }
        cursorTexture = texture
        cursorHotSpot = SIMD2(Float(cursor.hotSpotX), Float(cursor.hotSpotY))
        needsDisplay = true
    }

    func setNeedsDisplay() { needsDisplay = true }

    // MARK: Geometry

    /// Where the surface lands in a drawable of `size` pixels (aspect fit, centred).
    func surfaceFrame(in size: CGSize) -> CGRect {
        let (w, h) = surfaceSize
        guard w > 0, h > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / CGFloat(w), size.height / CGFloat(h))
        let width = CGFloat(w) * scale, height = CGFloat(h) * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func uniforms(for frame: CGRect, in size: CGSize) -> QuadUniforms {
        // frame uses a top-left origin; NDC has +y up.
        let centerX = (frame.midX / size.width) * 2 - 1
        let centerY = 1 - (frame.midY / size.height) * 2
        return QuadUniforms(scale: SIMD2(Float(frame.width / size.width), Float(frame.height / size.height)),
                            offset: SIMD2(Float(centerX), Float(centerY)))
    }

    // MARK: Drawing

    func draw(in layer: CAMetalLayer) {
        guard needsDisplay else { return }
        let size = layer.drawableSize
        guard size.width > 0, size.height > 0, let drawable = layer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else { return }
        needsDisplay = false
        commandBuffer.label = "Present frame"

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Surface pass"

        if let texture = surfaceTexture {
            let frame = surfaceFrame(in: size)
            var quad = uniforms(for: frame, in: size)
            let exact = abs(frame.width - CGFloat(texture.width)) < 0.5 && abs(frame.height - CGFloat(texture.height)) < 0.5
            encoder.setRenderPipelineState(surfacePipeline)
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(exact ? nearestSampler : linearSampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

            if showsCursorOverlay, let cursor = cursorTexture {
                let scale = frame.width / CGFloat(texture.width)
                let origin = SIMD2<Float>(cursorPosition.x - cursorHotSpot.x, cursorPosition.y - cursorHotSpot.y)
                let cursorFrame = CGRect(x: frame.minX + CGFloat(origin.x) * scale,
                                         y: frame.minY + CGFloat(origin.y) * scale,
                                         width: CGFloat(cursor.width) * scale,
                                         height: CGFloat(cursor.height) * scale)
                var cursorQuad = uniforms(for: cursorFrame, in: size)
                encoder.setRenderPipelineState(cursorPipeline)
                encoder.setVertexBytes(&cursorQuad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                encoder.setFragmentTexture(cursor, index: 0)
                encoder.setFragmentSamplerState(nearestSampler, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
