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

/// SwiftUI bridge that renders the fluid sim into a centered virtual cup and
/// forwards touches as pours. Used in the Simulator (and any device without
/// ARKit) — on a LiDAR device the real experience is `ARFluidView`.
struct MetalFluidView: UIViewRepresentable {
    let controller: SimulationController
    let touchSource: TouchPourSource

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

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
        view.onTouch = { [weak controller, touchSource] viewUV in
            guard let controller else { return }
            touchSource.touchMoved(toUV: controller.cupPose.cupUV(fromViewPoint: viewUV))
        }
        view.onTouchEnd = { [touchSource] in touchSource.end() }
        return view
    }

    func updateUIView(_ uiView: TouchReportingMTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        let controller: SimulationController
        var blitter: FluidBlitter?

        init(controller: SimulationController) { self.controller = controller }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            updateVirtualCup(for: size)
        }

        /// A centered circular virtual cup (kept circular in pixels for portrait).
        private func updateVirtualCup(for size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            let aspect = Float(size.width / size.height)
            var pose = CupPose.centeredDefault
            let r: Float = 0.44
            pose.axes = SIMD2<Float>(r, r * aspect)
            pose.confidence = 0
            if controller.cupPose != pose { controller.cupPose = pose }
        }

        func draw(in view: MTKView) {
            updateVirtualCup(for: view.drawableSize)
            controller.advance()
            guard let drawable = view.currentDrawable,
                  let pass = view.currentRenderPassDescriptor,
                  let blitter = blitter,
                  let cb = controller.ctx.queue.makeCommandBuffer() else { return }
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0.03, 0.03, 0.04, 1)
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
            blitter.encode(texture: controller.sim.outputTexture, pose: controller.cupPose, into: enc)
            enc.endEncoding()
            cb.present(drawable)
            cb.commit()
        }
    }
}
