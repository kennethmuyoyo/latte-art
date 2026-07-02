import Metal
import MetalKit
import simd

/// Draws the live camera texture as a full-screen, aspect-filled background that
/// the fluid overlay composites on top of (spec §7).
final class CameraBlitter {
    private let pipeline: MTLRenderPipelineState

    init(ctx: MetalContext, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = ctx.library.makeFunction(name: "fsQuadVertex")
        desc.fragmentFunction = ctx.library.makeFunction(name: "cameraFragment")
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        pipeline = try! ctx.device.makeRenderPipelineState(descriptor: desc)
    }

    func encode(texture: MTLTexture, viewSize: CGSize, into enc: MTLRenderCommandEncoder) {
        // Aspect fill: shrink the sampled UV region along the over-long axis.
        let texAspect = Float(texture.width) / Float(max(texture.height, 1))
        let viewAspect = Float(viewSize.width / max(viewSize.height, 1))
        var uvScale = SIMD2<Float>(1, 1)
        if texAspect > viewAspect {
            uvScale.x = viewAspect / texAspect
        } else {
            uvScale.y = texAspect / viewAspect
        }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentBytes(&uvScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
