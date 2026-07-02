import SwiftUI
import MetalKit
import simd

/// An MTKView subclass that reports touches as normalized view points `[0,1]`.
final class TouchReportingMTKView: MTKView {
    var onTouch: ((SIMD2<Float>) -> Void)?
    var onTouchEnd: (() -> Void)?

    private func report(_ touches: Set<UITouch>) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        let uv = SIMD2<Float>(Float(p.x / max(bounds.width, 1)),
                              Float(p.y / max(bounds.height, 1)))
        onTouch?(uv)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { onTouchEnd?() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { onTouchEnd?() }
}

/// SwiftUI bridge that renders the fluid sim and forwards touches to a
/// `TouchPourSource`. In the Simulator this is the whole interactive experience;
/// on device the AR compositor renders behind it.
struct MetalFluidView: UIViewRepresentable {
    let controller: SimulationController
    let touchSource: TouchPourSource
    var perception: PerceptionManager? = nil

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, perception: perception) }

    func makeUIView(context: Context) -> TouchReportingMTKView {
        let view = TouchReportingMTKView(frame: .zero, device: controller.ctx.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.isOpaque = false
        view.backgroundColor = .black
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        context.coordinator.blitter = FluidBlitter(ctx: controller.ctx,
                                                   colorPixelFormat: view.colorPixelFormat)
        context.coordinator.cameraBlitter = CameraBlitter(ctx: controller.ctx,
                                                          colorPixelFormat: view.colorPixelFormat)
        let usesCamera = perception != nil
        view.onTouch = { [weak controller, weak view, touchSource, perception] viewUV in
            guard let controller, let view else { return }
            // Before a cup is acquired on device, a tap PLACES the cup (so the
            // user is never stuck if auto-detection misses). Once it's locked,
            // touches drive the pour (also the whole interaction in the Simulator).
            if usesCamera && controller.cupPose.confidence == 0 {
                // Place the cup; its surface depth is then tracked continuously.
                controller.cupPose = Coordinator.placedCup(at: viewUV, viewSize: view.bounds.size)
            } else {
                touchSource.touchMoved(toUV: controller.cupPose.cupUV(fromViewPoint: viewUV))
            }
        }
        view.onTouchEnd = { [touchSource] in touchSource.end() }
        return view
    }

    func updateUIView(_ uiView: TouchReportingMTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        let controller: SimulationController
        let perception: PerceptionManager?
        var blitter: FluidBlitter?
        var cameraBlitter: CameraBlitter?

        init(controller: SimulationController, perception: PerceptionManager?) {
            self.controller = controller
            self.perception = perception
        }

        private var usesCamera: Bool { perception != nil }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            if !usesCamera { updateVirtualCup(for: size) }
        }

        /// Simulator only: a centered circular virtual cup (there's no camera to
        /// detect a real one). Kept circular in pixels for the portrait screen.
        private func updateVirtualCup(for size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            let aspect = Float(size.width / size.height)
            var pose = CupPose.centeredDefault
            let r: Float = 0.44
            pose.axes = SIMD2<Float>(r, r * aspect)
            pose.confidence = 0
            if controller.cupPose != pose { controller.cupPose = pose }
        }

        /// Build a circular cup pose centered on a tapped point (device fallback
        /// for "get a cup"). `confidence = 1` marks it as acquired.
        static func placedCup(at viewUV: SIMD2<Float>, viewSize: CGSize) -> CupPose {
            let aspect = viewSize.height > 0 ? Float(viewSize.width / viewSize.height) : 1
            let r: Float = 0.42
            return CupPose(center: viewUV, axes: SIMD2<Float>(r, r * aspect),
                           angle: 0, confidence: 1)
        }

        /// Aspect-fill scale mapping a full-frame texture (camera/depth) onto the
        /// view — shared by the camera background and depth sampling so they align.
        static func aspectFillScale(texW: Int, texH: Int, viewSize: CGSize) -> SIMD2<Float> {
            let texAspect = Float(texW) / Float(max(texH, 1))
            let viewAspect = viewSize.height > 0 ? Float(viewSize.width / viewSize.height) : 1
            return texAspect > viewAspect
                ? SIMD2<Float>(viewAspect / texAspect, 1)
                : SIMD2<Float>(1, texAspect / viewAspect)
        }

        /// Map a view-normalized point to the aspect-filled texture's UV.
        static func aspectFillUV(viewUV: SIMD2<Float>, texW: Int, texH: Int,
                                 viewSize: CGSize) -> SIMD2<Float> {
            let scale = aspectFillScale(texW: texW, texH: texH, viewSize: viewSize)
            return (viewUV - 0.5) * scale + 0.5
        }

        func draw(in view: MTKView) {
            if !usesCamera { updateVirtualCup(for: view.drawableSize) }
            // Let perception map the cup pose into the depth map's aspect-fill space.
            if view.drawableSize.height > 0 {
                perception?.viewAspect = Float(view.drawableSize.width / view.drawableSize.height)
            }
            controller.advance()
            guard let drawable = view.currentDrawable,
                  let pass = view.currentRenderPassDescriptor,
                  let blitter = blitter,
                  let cb = controller.ctx.queue.makeCommandBuffer() else { return }
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0.03, 0.03, 0.04, 1)
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }

            // Camera background first (device only).
            if let cam = perception?.currentCameraTexture() {
                cameraBlitter?.encode(texture: cam, viewSize: view.drawableSize, into: enc)
            }
            // The fluid is composited ONLY once a cup has been acquired — detected
            // by Vision or tapped. Before that, the user just sees the live cup.
            let hasCup = !usesCamera || controller.cupPose.confidence > 0
            if hasCup {
                // Depth-occluded draw when LiDAR depth + a locked cup plane exist,
                // so a jug/hand/stream in front of the cup shows through the coffee.
                if let depth = perception?.currentDepthTexture(),
                   let cupDepth = perception?.cupDepth {
                    let size = SIMD2<Float>(Float(view.drawableSize.width),
                                            Float(view.drawableSize.height))
                    let scale = Coordinator.aspectFillScale(texW: depth.width, texH: depth.height,
                                                            viewSize: view.drawableSize)
                    let params = FluidBlitter.OcclusionParams(
                        drawableSize: size, depthUVScale: scale,
                        cupDepth: cupDepth, margin: perception?.occlusionMargin ?? 0.03,
                        hasDepth: 1)
                    blitter.encode(texture: controller.sim.outputTexture, pose: controller.cupPose,
                                   depth: depth, params: params, into: enc)
                } else {
                    blitter.encode(texture: controller.sim.outputTexture,
                                   pose: controller.cupPose, into: enc)
                }
            }
            enc.endEncoding()
            cb.present(drawable)
            cb.commit()
        }
    }
}
