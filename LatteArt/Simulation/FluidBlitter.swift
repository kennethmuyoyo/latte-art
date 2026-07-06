import MetalKit
import SwiftUI
import simd

/// Swift mirror of the Metal `CupQuadUniforms` — placement of the sim quad in
/// clip space. Field order/size must match `Fluid.metal`.
struct CupQuadUniforms {
    var centerNDC: SIMD2<Float>
    var axes: SIMD2<Float>
    var angle: Float
}

/// Drives the loop: controller.advance → solver.step (inside advance) → draw the
/// dye texture onto the cup quad. The MTKView's display link is the sim clock
/// (fixed dt — semi-Lagrangian advection doesn't care about hiccups). The dye
/// texture is composited with alpha blending so it can sit over anything (dark
/// grey here, the camera later).
final class FluidBlitter: NSObject, MTKViewDelegate {
    let context: MetalContext
    private let renderPipeline: MTLRenderPipelineState
    weak var controller: SimulationController?

    /// Where the cup sits on screen; the quad follows it.
    var cupPose: CupPose = .centeredDefault

    init?(context: MetalContext) {
        guard let vfn = context.library.makeFunction(name: "v_cupQuad"),
              let ffn = context.library.makeFunction(name: "f_latte") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        let att = desc.colorAttachments[0]!
        att.pixelFormat = .bgra8Unorm
        att.isBlendingEnabled = true
        att.sourceRGBBlendFactor = .sourceAlpha
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha
        att.sourceAlphaBlendFactor = .sourceAlpha
        att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipe = try? context.device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.context = context
        self.renderPipeline = pipe
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let cb = context.queue.makeCommandBuffer() else { return }

        controller?.advance(dt: 1.0 / 60.0, commandBuffer: cb)

        if let rpd = view.currentRenderPassDescriptor,
           let enc = cb.makeRenderCommandEncoder(descriptor: rpd),
           let dye = controller?.dyeTexture {
            enc.setRenderPipelineState(renderPipeline)
            var uniforms = cupQuadUniforms()
            enc.setVertexBytes(&uniforms, length: MemoryLayout<CupQuadUniforms>.stride, index: 0)
            enc.setFragmentTexture(dye, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            if let drawable = view.currentDrawable { cb.present(drawable) }
        }
        cb.commit()
    }

    /// Convert the normalized-view (y-down) `CupPose` into clip-space uniforms.
    /// center: (2cx−1, 1−2cy). Corner offsets scale by axes in NDC units (2·o)
    /// with BOTH components positive — the vertex shader's UV y-flip already
    /// reconciles NDC-y-up vs texture-y-down; negating axes.y here too would
    /// double-flip and mirror the drawing vertically. Angle is negated because
    /// CupPose.angle is defined in y-down view space while NDC rotates y-up
    /// (invisible today: angle is 0 everywhere until tracking provides it).
    private func cupQuadUniforms() -> CupQuadUniforms {
        let centerNDC = SIMD2<Float>(2 * cupPose.center.x - 1,
                                     1 - 2 * cupPose.center.y)
        let axes = SIMD2<Float>(2 * cupPose.axes.x, 2 * cupPose.axes.y)
        return CupQuadUniforms(centerNDC: centerNDC, axes: axes, angle: -cupPose.angle)
    }
}

/// SwiftUI wrapper. Square by convention — the sim domain is the cup disc.
struct SimulationView: UIViewRepresentable {
    let blitter: FluidBlitter

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: blitter.context.device)
        v.delegate = blitter
        v.preferredFramesPerSecond = 60
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
        return v
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
