import Metal
import MetalKit
import simd

/// Draws the sim's output texture into the cup's on-screen ellipse. The sim
/// renders its fluid inside an inscribed circle with alpha 0 outside; drawing
/// that texture into the cup's bounding-box quad lands the circle on the rim.
/// Used by the Simulator's `MetalFluidView`.
final class FluidBlitter {
    /// Matches `QuadRect` in Fluid.metal.
    private struct QuadRect { var centerNDC: SIMD2<Float>; var halfSizeNDC: SIMD2<Float> }

    private let ctx: MetalContext
    private let plainPipeline: MTLRenderPipelineState

    init(ctx: MetalContext, colorPixelFormat: MTLPixelFormat) {
        self.ctx = ctx
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = ctx.library.makeFunction(name: "texturedQuadVertex")
        desc.fragmentFunction = ctx.library.makeFunction(name: "fsQuadFragment")
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        let c = desc.colorAttachments[0]!
        c.isBlendingEnabled = true
        c.rgbBlendOperation = .add
        c.alphaBlendOperation = .add
        c.sourceRGBBlendFactor = .sourceAlpha
        c.sourceAlphaBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        plainPipeline = try! ctx.device.makeRenderPipelineState(descriptor: desc)
    }

    private func quadRect(for pose: CupPose) -> QuadRect {
        // Normalized view (y-down, [0,1]) -> NDC (y-up, [-1,1]).
        QuadRect(centerNDC: SIMD2<Float>(pose.center.x * 2 - 1, 1 - pose.center.y * 2),
                 halfSizeNDC: SIMD2<Float>(pose.axes.x * 2, pose.axes.y * 2))
    }

    func encode(texture: MTLTexture, pose: CupPose, into enc: MTLRenderCommandEncoder) {
        var rect = quadRect(for: pose)
        enc.setRenderPipelineState(plainPipeline)
        enc.setVertexBytes(&rect, length: MemoryLayout<QuadRect>.stride, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
