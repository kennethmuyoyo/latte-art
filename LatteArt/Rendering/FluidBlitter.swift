import Metal
import MetalKit
import simd

/// Draws the sim's output texture into the cup's on-screen ellipse. The sim
/// renders its fluid inside an inscribed circle with alpha 0 outside; drawing
/// that texture into the cup's bounding-box quad lands the circle on the rim
/// (spec §7). On LiDAR devices it uses a depth-occlusion fragment so real objects
/// in front of the cup (jug/hand/stream) show through the coffee (spec §13).
final class FluidBlitter {
    /// Matches `QuadRect` in Fluid.metal.
    private struct QuadRect { var centerNDC: SIMD2<Float>; var halfSizeNDC: SIMD2<Float> }
    /// Matches `OcclusionParams` in Fluid.metal.
    struct OcclusionParams {
        var drawableSize: SIMD2<Float>
        var depthUVScale: SIMD2<Float>
        var cupDepth: Float
        var margin: Float
        var hasDepth: Float
    }

    private let ctx: MetalContext
    private let plainPipeline: MTLRenderPipelineState
    private let occlusionPipeline: MTLRenderPipelineState

    init(ctx: MetalContext, colorPixelFormat: MTLPixelFormat) {
        self.ctx = ctx
        plainPipeline = FluidBlitter.pipeline(ctx: ctx, fragment: "fsQuadFragment",
                                              colorPixelFormat: colorPixelFormat)
        occlusionPipeline = FluidBlitter.pipeline(ctx: ctx, fragment: "coffeeOccludedFragment",
                                                  colorPixelFormat: colorPixelFormat)
    }

    private static func pipeline(ctx: MetalContext, fragment: String,
                                 colorPixelFormat: MTLPixelFormat) -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = ctx.library.makeFunction(name: "texturedQuadVertex")
        desc.fragmentFunction = ctx.library.makeFunction(name: fragment)
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        let c = desc.colorAttachments[0]!
        c.isBlendingEnabled = true
        c.rgbBlendOperation = .add
        c.alphaBlendOperation = .add
        c.sourceRGBBlendFactor = .sourceAlpha
        c.sourceAlphaBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try! ctx.device.makeRenderPipelineState(descriptor: desc)
    }

    private func quadRect(for pose: CupPose) -> QuadRect {
        // Normalized view (y-down, [0,1]) -> NDC (y-up, [-1,1]).
        QuadRect(centerNDC: SIMD2<Float>(pose.center.x * 2 - 1, 1 - pose.center.y * 2),
                 halfSizeNDC: SIMD2<Float>(pose.axes.x * 2, pose.axes.y * 2))
    }

    /// Plain draw (Simulator / no depth).
    func encode(texture: MTLTexture, pose: CupPose, into enc: MTLRenderCommandEncoder) {
        var rect = quadRect(for: pose)
        enc.setRenderPipelineState(plainPipeline)
        enc.setVertexBytes(&rect, length: MemoryLayout<QuadRect>.stride, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Depth-occluded draw (LiDAR device).
    func encode(texture: MTLTexture, pose: CupPose, depth: MTLTexture,
                params: OcclusionParams, into enc: MTLRenderCommandEncoder) {
        var rect = quadRect(for: pose)
        var p = params
        enc.setRenderPipelineState(occlusionPipeline)
        enc.setVertexBytes(&rect, length: MemoryLayout<QuadRect>.stride, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentTexture(depth, index: 1)
        enc.setFragmentBytes(&p, length: MemoryLayout<OcclusionParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
