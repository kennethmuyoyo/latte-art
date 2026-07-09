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

/// Swift mirror of the Metal `DepthOcclusionUniform` — everything the
/// fragment shader needs to compare ARKit's real per-pixel scene depth
/// against the tracked cup plane's depth at that same pixel, and hide the
/// surface exactly where the real world (pitcher, hand) is in front. Field
/// order/size must match `Fluid.metal`. Built per ARKit frame by
/// `CameraPourCoordinator.updateSceneDepth`; `drawableSize` is the one field
/// the blitter fills itself at draw time (only it knows the render target).
struct DepthOcclusionUniform {
    var inverseViewProjection: simd_float4x4
    var cameraPos: SIMD3<Float>
    var cameraForward: SIMD3<Float>
    var planePoint: SIMD3<Float>
    var planeNormal: SIMD3<Float>
    var viewToImage: SIMD4<Float>      // CGAffineTransform a,b,c,d: view UV -> depth-map UV
    var viewToImageT: SIMD2<Float>     // tx, ty
    var drawableSize: SIMD2<Float>
    var enabled: Float
    var margin: Float
    var pad: SIMD2<Float> = .zero

    static let disabled = DepthOcclusionUniform(
        inverseViewProjection: matrix_identity_float4x4,
        cameraPos: .zero, cameraForward: SIMD3<Float>(0, 0, -1),
        planePoint: .zero, planeNormal: SIMD3<Float>(0, 1, 0),
        viewToImage: SIMD4<Float>(1, 0, 0, 1), viewToImageT: .zero,
        drawableSize: .zero, enabled: 0, margin: 0)
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

    /// EXACT screen-space conjugate-diameter vectors of the cup ellipse,
    /// normalized the same way `CupPose.center` is (x as a fraction of view
    /// WIDTH, y of view HEIGHT, y-down). When set (the camera path), the quad
    /// corners are placed with `center + c.x·p + c.y·q` — the exact linear map
    /// from cup UV to screen — instead of `cupPose`'s (axes, angle) eigen
    /// summary. That summary is only safe for the ellipse OUTLINE: it drops a
    /// rotation term that misplaces interior points, and near a circular
    /// ellipse (the normal near-top-down view) the major-axis direction is
    /// ill-conditioned, so `angle` swings with tag noise — which showed up as
    /// the whole disc visibly rotating during a pour. `nil` (debug harness)
    /// falls back to the axes/angle placement.
    var cupConjugates: (p: SIMD2<Float>, q: SIMD2<Float>)?

    /// Whether to paint the disc this frame. The camera path sets this `false`
    /// until the cup is tracked, so no blob floats over the live feed before a
    /// cup is found. Debug harness leaves it `true` (always drawn).
    var drawsDisc = true

    /// Up to 2 real, depth-verified occlusion holes this frame (one per
    /// pitcher tag — spout, back) — `CameraPourCoordinator` only populates a
    /// slot when it's ray-cast the tag's actual position against the cup's
    /// tracked plane and confirmed the tag is genuinely closer to the camera
    /// there, not merely "a tag is visible". Radius comes from the tag's real
    /// physical size, not a guessed constant — see `Occluder`. FALLBACK path
    /// only — ignored by the shader whenever per-pixel scene depth is active.
    var occluders: [Occluder] = []

    // Per-pixel scene-depth occlusion (LiDAR) — set fresh each ARKit frame by
    // `CameraPourCoordinator.updateSceneDepth`, consumed by `draw(in:)`. The
    // CVMetalTexture wrapper is held alongside the MTLTexture because the
    // texture's pixels live in the CVPixelBuffer's IOSurface — dropping the
    // wrapper while the GPU still reads the texture is a use-after-free.
    private var sceneDepthTexture: MTLTexture?
    private var sceneDepthHolder: Any?
    private var depthUniform = DepthOcclusionUniform.disabled

    func setSceneDepth(texture: MTLTexture, holder: Any, uniform: DepthOcclusionUniform) {
        sceneDepthTexture = texture
        sceneDepthHolder = holder
        depthUniform = uniform
    }

    func clearSceneDepth() {
        sceneDepthTexture = nil
        sceneDepthHolder = nil
        depthUniform = .disabled
    }

    /// Bound at the depth slot when no scene depth is available this frame —
    /// the shader's depth branch is disabled then and never samples it, but
    /// Metal argument validation still requires SOMETHING bound at every
    /// declared texture index.
    private lazy var placeholderDepthTexture: MTLTexture? = {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = context.device.makeTexture(descriptor: desc) else { return nil }
        var zero: Float = 0
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                    withBytes: &zero, bytesPerRow: MemoryLayout<Float>.size)
        return tex
    }()

    /// One-shot photo capture of the sim overlay: set by `captureOverlay(_:)`,
    /// consumed by the next `draw(in:)`, which renders the disc into its own
    /// offscreen pass — with ALL occlusion disabled, so the photo shows the
    /// full circle of art rather than the hole the live view cuts for the
    /// pitcher — and hands it back as a UIImage (transparent everywhere except
    /// the painted disc, ready to composite over a camera snapshot).
    private var pendingCapture: ((UIImage?) -> Void)?

    /// Completion is always called, on the main thread; `nil` if the frame
    /// couldn't be read back.
    func captureOverlay(_ completion: @escaping (UIImage?) -> Void) {
        pendingCapture = completion
    }

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
                // Occlusion disabled BY DESIGN: the pitcher cutout in the
                // surface (both the per-pixel scene-depth silhouette and the
                // tag-circle fallback) read as visually bad on device — the
                // surface now always draws fully opaque. All the upstream
                // plumbing (depth capture, occluder computation) stays wired;
                // re-enabling is just restoring the real uniforms here.
                var occl = OcclusionUniform(uv0: .zero, radius0: 0, active0: 0,
                                            uv1: .zero, radius1: 0, active1: 0)
                enc.setFragmentBytes(&occl, length: MemoryLayout<OcclusionUniform>.stride, index: 0)
                var depth = DepthOcclusionUniform.disabled
                enc.setFragmentTexture(placeholderDepthTexture, index: 1)
                enc.setFragmentBytes(&depth, length: MemoryLayout<DepthOcclusionUniform>.stride, index: 1)
                enc.setFragmentTexture(dye, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            enc.endEncoding()
            if let drawable = view.currentDrawable { cb.present(drawable) }
        }
        if let capture = pendingCapture {
            pendingCapture = nil
            encodeCleanCapture(in: cb, view: view, completion: capture)
        }
        cb.commit()
    }

    /// Renders the disc into an offscreen texture in its own pass, with both
    /// occlusion paths (per-pixel scene depth AND the tag-circle fallback)
    /// disabled — the photo should show the whole pattern, not the live
    /// view's pitcher cutout — then reads it back as a UIImage once the GPU
    /// finishes. Completion is always called, on the main thread.
    private func encodeCleanCapture(in cb: MTLCommandBuffer, view: MTKView,
                                    completion: @escaping (UIImage?) -> Void) {
        let size = view.drawableSize
        guard drawsDisc, let dye = controller?.dyeTexture,
              size.width > 1, size.height > 1 else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height),
            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared            // CPU-readable directly, no blit copy needed
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let target = context.device.makeTexture(descriptor: desc) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        rpd.colorAttachments[0].texture = target
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        enc.setRenderPipelineState(renderPipeline)
        let vertices = cupQuadVertices(viewSize: view.bounds.size)
        vertices.withUnsafeBytes { buf in
            enc.setVertexBytes(buf.baseAddress!, length: buf.count, index: 0)
        }
        var occl = OcclusionUniform(uv0: .zero, radius0: 0, active0: 0,
                                    uv1: .zero, radius1: 0, active1: 0)
        enc.setFragmentBytes(&occl, length: MemoryLayout<OcclusionUniform>.stride, index: 0)
        var depth = DepthOcclusionUniform.disabled
        enc.setFragmentBytes(&depth, length: MemoryLayout<DepthOcclusionUniform>.stride, index: 1)
        enc.setFragmentTexture(dye, index: 0)
        enc.setFragmentTexture(placeholderDepthTexture, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.addCompletedHandler { _ in
            let image = Self.image(fromBGRA: target)
            DispatchQueue.main.async { completion(image) }
        }
    }

    private static func image(fromBGRA texture: MTLTexture) -> UIImage? {
        let w = texture.width, h = texture.height
        guard w > 0, h > 0 else { return nil }
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        bytes.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        // .bgra8Unorm + blending into a transparent clear leaves premultiplied
        // BGRA — that's byteOrder32Little + premultipliedFirst in CG terms.
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                | CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: info, provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
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
    /// conversion below, so it never needs to touch the rotation's sign.
    ///
    /// UV is NOT flipped: corner (-1,-1) sits at the ellipse's TOP-left in
    /// y-down pixel space (negative pixel-y offset = up on screen), which is
    /// exactly where cup-space/texture v=0 belongs — both are y-down, so the
    /// square's corners map to texture UV directly. The `uv.y = 1 - uv.y`
    /// flip that used to live here was a leftover from when the corners were
    /// interpreted in y-UP NDC; once placement moved to y-down pixel space it
    /// became a double-flip that vertically MIRRORED the disc — a pour toward
    /// one rim edge painted at the opposite edge.
    private func cupQuadVertices(viewSize: CGSize) -> [CupVertex] {
        let w = Float(viewSize.width), h = Float(viewSize.height)
        guard w > 1, h > 1 else {
            return Self.corners.map { CupVertex(posNDC: .zero, uv: $0 * 0.5 + 0.5) }
        }
        let centerPx = SIMD2<Float>(cupPose.center.x * w, cupPose.center.y * h)

        return Self.corners.map { c in
            let posPx: SIMD2<Float>
            if let (pn, qn) = cupConjugates {
                // Exact conjugate-diameter map (see `cupConjugates`): no
                // eigen summary, no angle — content can't spin with noise.
                let p = SIMD2<Float>(pn.x * w, pn.y * h)
                let q = SIMD2<Float>(qn.x * w, qn.y * h)
                posPx = centerPx + c.x * p + c.y * q
            } else {
                let semiPx = SIMD2<Float>(cupPose.axes.x * w, cupPose.axes.y * h)
                let ca = cos(cupPose.angle), sa = sin(cupPose.angle)
                let s = SIMD2<Float>(c.x * semiPx.x, c.y * semiPx.y)           // isotropic pixel-space scale
                posPx = centerPx + SIMD2<Float>(s.x * ca - s.y * sa, s.x * sa + s.y * ca) // proper rotation (pixels)
            }
            let posNDC = SIMD2<Float>(2 * posPx.x / w - 1, 1 - 2 * posPx.y / h) // anisotropic step, but no rotation here
            return CupVertex(posNDC: posNDC, uv: c * 0.5 + 0.5)
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
