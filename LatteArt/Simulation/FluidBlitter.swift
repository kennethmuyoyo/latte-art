import MetalKit
import SwiftUI
import simd

/// Swift mirror of the Metal `CupVertex` — one corner of the sim quad,
/// already fully placed in clip space. Field order/size must match
/// `Fluid.metal`.
///
/// The quad's 4 corners are computed here (not in the vertex shader) because
/// getting an ELLIPSE's rotation right requires rotating in an isotropic
/// space — real pixels, where x and y mean the same physical distance — and
/// then converting to clip space last. Clip space itself is anisotropic
/// whenever the viewport isn't square (any full-screen portrait view): a
/// given NDC offset maps to a different pixel distance in x than in y, so
/// rotating a pre-scaled-to-NDC quad (as the previous version did) silently
/// skews it instead of rotating it. Doing the trig here, in `Float` pixel
/// math, sidesteps that entirely — the shader just places pre-computed points.
struct CupVertex {
    var posNDC: SIMD2<Float>
    var uv: SIMD2<Float>
}

/// Swift mirror of the Metal `OcclusionUniform` — where (and whether) to cut
/// a hole in the disc for the real pitcher, one slot per pitcher tag (spout,
/// back). Field order/size must match `Fluid.metal`.
struct OcclusionUniform {
    var uv0: SIMD2<Float>
    var radius0: Float
    var active0: Float
    var uv1: SIMD2<Float>
    var radius1: Float
    var active1: Float
}

/// One real, depth-verified occlusion hole — see `CameraPourCoordinator`'s
/// depth test for how this gets decided (not just "a tag is visible").
struct Occluder {
    var uv: SIMD2<Float>
    var radius: Float
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

    /// Whether to paint the disc this frame. The camera path sets this `false`
    /// until the cup is tracked, so no blob floats over the live feed before a
    /// cup is found. Debug harness leaves it `true` (always drawn).
    var drawsDisc = true

    /// Up to 2 real, depth-verified occlusion holes this frame (one per
    /// pitcher tag — spout, back) — `CameraPourCoordinator` only populates a
    /// slot when it's ray-cast the tag's actual position against the cup's
    /// tracked plane and confirmed the tag is genuinely closer to the camera
    /// there, not merely "a tag is visible". Radius comes from the tag's real
    /// physical size, not a guessed constant — see `Occluder`.
    var occluders: [Occluder] = []

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

        // Always open the pass (it clears the view — transparent over the
        // camera, grey in the debug harness); only encode the disc quad when
        // it should be visible, so hiding it leaves a clean camera feed.
        if let rpd = view.currentRenderPassDescriptor,
           let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            if drawsDisc, let dye = controller?.dyeTexture {
                enc.setRenderPipelineState(renderPipeline)
                let vertices = cupQuadVertices(viewSize: view.bounds.size)
                vertices.withUnsafeBytes { buf in
                    enc.setVertexBytes(buf.baseAddress!, length: buf.count, index: 0)
                }
                var occl = OcclusionUniform(
                    uv0: occluders.count > 0 ? occluders[0].uv : .zero,
                    radius0: occluders.count > 0 ? occluders[0].radius : 0,
                    active0: occluders.count > 0 ? 1 : 0,
                    uv1: occluders.count > 1 ? occluders[1].uv : .zero,
                    radius1: occluders.count > 1 ? occluders[1].radius : 0,
                    active1: occluders.count > 1 ? 1 : 0)
                enc.setFragmentBytes(&occl, length: MemoryLayout<OcclusionUniform>.stride, index: 0)
                enc.setFragmentTexture(dye, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            enc.endEncoding()
            if let drawable = view.currentDrawable { cb.present(drawable) }
        }
        cb.commit()
    }

    /// The unit-square corners the quad is built from, in the same order the
    /// shader used to hard-code them (matches the `triangleStrip` draw call).
    private static let corners: [SIMD2<Float>] = [
        SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(1, 1),
    ]

    /// Places the cup quad's 4 corners directly in clip space.
    ///
    /// `CupPose.axes`/`.center` are normalized anisotropically (x as a
    /// fraction of view WIDTH, y as a fraction of view HEIGHT — see
    /// `CupPose`'s doc comment) against the SAME points-based view size
    /// `CameraPourCoordinator` used when it built the pose (`ARSCNView.bounds`,
    /// via `viewportSize`). Recovering an isotropic "real distance" unit to
    /// rotate in — so a rotation is an actual rotation, not a skew — only
    /// requires multiplying back by SOME consistent width/height; it doesn't
    /// have to be pixels. Using `view.bounds.size` (points) here, matching
    /// that same points-based unit, avoids a second, independent dependency
    /// on Metal's drawable-resize timing (`drawableSize` starts at zero until
    /// the view's first layout/resize callback, and this view starts with
    /// `frame: .zero`) — one less thing that can be transiently wrong.
    ///
    /// NOT negated: `angle`, `centerPx`, and `semiPx` are all still in y-down
    /// PIXEL space at this point (matching `CupPose.angle`'s own defined
    /// convention — see `cupPose(from:)`'s `px()` helper, "pixels, y-down").
    /// The y-up NDC flip only happens after rotation, in the position
    /// conversion below, so it never needs to touch the rotation's sign — the
    /// same reasoning the SwiftUI guide ring's `rotationEffect(.radians(pose.angle))`
    /// already relies on (also unnegated, also rotating before any flip).
    private func cupQuadVertices(viewSize: CGSize) -> [CupVertex] {
        let w = Float(viewSize.width), h = Float(viewSize.height)
        guard w > 1, h > 1 else {
            return Self.corners.map { CupVertex(posNDC: .zero, uv: $0 * 0.5 + 0.5) }
        }
        let semiPx = SIMD2<Float>(cupPose.axes.x * w, cupPose.axes.y * h)
        let centerPx = SIMD2<Float>(cupPose.center.x * w, cupPose.center.y * h)
        let angle = cupPose.angle
        let ca = cos(angle), sa = sin(angle)

        return Self.corners.map { c in
            let s = SIMD2<Float>(c.x * semiPx.x, c.y * semiPx.y)               // isotropic pixel-space scale
            let r = SIMD2<Float>(s.x * ca - s.y * sa, s.x * sa + s.y * ca)     // proper rotation (pixels)
            let posPx = centerPx + r
            let posNDC = SIMD2<Float>(2 * posPx.x / w - 1, 1 - 2 * posPx.y / h) // anisotropic step, but no rotation here
            var uv = c * 0.5 + 0.5
            uv.y = 1 - uv.y   // NDC-y-up vs texture-y-down
            return CupVertex(posNDC: posNDC, uv: uv)
        }
    }
}

/// SwiftUI wrapper. In the debug harness it's a square over dark grey; over the
/// camera it's a full-screen transparent layer so only the cup disc paints and
/// the live camera shows through everywhere else.
struct SimulationView: UIViewRepresentable {
    let blitter: FluidBlitter
    /// `true` = clear to transparent (camera overlay); `false` = opaque grey (debug).
    var transparent: Bool = false

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: blitter.context.device)
        v.delegate = blitter
        v.preferredFramesPerSecond = 60
        v.colorPixelFormat = .bgra8Unorm
        if transparent {
            v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            v.isOpaque = false
            v.backgroundColor = .clear
        } else {
            v.clearColor = MTLClearColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
        }
        return v
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
