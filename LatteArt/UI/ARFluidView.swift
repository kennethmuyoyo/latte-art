import SwiftUI
import ARKit
import SceneKit
import simd

/// ARKit render path (LiDAR device). The user registers the cup by tapping its 3
/// rim dots (no global autodetection): each tap SEEDS a tracker with that dot's
/// color + position. Every frame each dot is then tracked LOCALLY (a small search
/// around its last position for its seeded color), unprojected through LiDAR to a
/// world point, and the 3 points define the rim circle — so the coffee disc
/// FOLLOWS the moving cup while the camera stays put.
struct ARFluidView: UIViewRepresentable {
    @ObservedObject var controller: SimulationController
    let touchSource: TouchPourSource

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, touchSource: touchSource) }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.delegate = context.coordinator
        view.session.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true
        view.scene = SCNScene()
        context.coordinator.sceneView = view

        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        view.session.run(config)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    /// One rim dot: its seeded chroma (lighting-independent) + last known image
    /// position + last world position.
    private struct TrackedDot {
        var cb: Float, cr: Float
        var img: SIMD2<Float>
        var world: SIMD3<Float>
    }

    final class Coordinator: NSObject, ARSCNViewDelegate, ARSessionDelegate {
        weak var sceneView: ARSCNView?
        let controller: SimulationController
        let touchSource: TouchPourSource

        private var dots: [TrackedDot] = []
        private var registered = false
        private var lockedRadius: Float = 0.04
        private var coffeeNode: SCNNode?
        private var coffeePlane: SCNPlane?
        private var smoothedCenter: SIMD3<Float>?
        private let smoothing: Float = 0.2
        private let searchHalf = 34          // local color-search window (px)
        private let chromaTol: Float = 20    // color match tolerance

        init(controller: SimulationController, touchSource: TouchPourSource) {
            self.controller = controller
            self.touchSource = touchSource
        }

        // MARK: - Tap to seed the 3 rim dots

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let sv = sceneView, !controller.cupRegistered,
                  let frame = sv.session.currentFrame else { return }
            let pt = g.location(in: sv)
            guard let imgPx = imagePx(fromScreen: pt, frame: frame, viewport: sv.bounds.size),
                  let chroma = chroma(at: imgPx, image: frame.capturedImage),
                  let world = worldPoint(atImagePx: imgPx, frame: frame) else { return }

            dots.append(TrackedDot(cb: chroma.0, cr: chroma.1, img: imgPx, world: world))
            controller.tappedPoints = dots.map { screenPoint(world: $0.world, in: sv) }
            if dots.count == 3 { registerCup(in: sv) }
        }

        private func registerCup(in sv: ARSCNView) {
            // Robust radius: mean distance from the centroid to the 3 points.
            // (Circumradius blows up for near-collinear / depth-noisy points.)
            let world = dots.map { $0.world }
            let c = centroid(world)
            let meanR = world.reduce(Float(0)) { $0 + simd_distance($1, c) } / Float(world.count)
            lockedRadius = min(max(meanR, 0.02), 0.12)   // clamp to a sane cup range

            let plane = SCNPlane(width: CGFloat(lockedRadius * 2), height: CGFloat(lockedRadius * 2))
            let mat = plane.firstMaterial!
            mat.lightingModel = .constant           // unlit: show the crema texture as-is
            mat.diffuse.contents = controller.sim.outputTexture
            mat.isDoubleSided = true
            mat.blendMode = .alpha                  // feathered alpha from the texture
            mat.writesToDepthBuffer = false
            mat.readsFromDepthBuffer = false
            let node = SCNNode(geometry: plane)
            node.eulerAngles.x = -.pi / 2           // lay flat (normal → +y, level water)
            sv.scene.rootNode.addChildNode(node)
            coffeeNode = node; coffeePlane = plane

            registered = true
            controller.cupRegistered = true
            if controller.cupPose.confidence == 0 {
                controller.cupPose = CupPose(center: SIMD2<Float>(0.5, 0.5),
                                             axes: SIMD2<Float>(0.2, 0.2), angle: 0, confidence: 1)
            }
        }

        // MARK: - Drag to pour

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let sv = sceneView, controller.cupRegistered else { return }
            switch g.state {
            case .changed:
                let p = g.location(in: sv)
                let uv = SIMD2<Float>(Float(p.x / max(sv.bounds.width, 1)),
                                      Float(p.y / max(sv.bounds.height, 1)))
                touchSource.touchMoved(toUV: controller.cupPose.cupUV(fromViewPoint: uv))
            case .ended, .cancelled, .failed:
                touchSource.end()
            default:
                break
            }
        }

        // MARK: - Per-frame: track dots, place disc, advance sim

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            controller.advance()
            guard let sv = sceneView else { return }

            // User asked to re-register.
            if !controller.cupRegistered, registered { reset() }
            guard registered, coffeeNode != nil else { return }

            trackDots(frame: frame)               // follow the moving cup
            let up = SIMD3<Float>(0, 1, 0)
            let c = centroid(dots.map { $0.world })
            let sc = smoothedCenter.map { $0 * (1 - smoothing) + c * smoothing } ?? c
            smoothedCenter = sc
            controller.tappedPoints = dots.map { screenPoint(world: $0.world, in: sv) }

            SCNTransaction.begin(); SCNTransaction.disableActions = true
            coffeeNode?.simdWorldPosition = sc + up * (controller.fillLevel * controller.surfaceFillRise
                                                       - controller.surfaceDrop)
            let d = CGFloat(lockedRadius * controller.radiusScale * 2)
            coffeePlane?.width = d; coffeePlane?.height = d
            SCNTransaction.commit()

            if let node = coffeeNode, let pose = projectedPose(of: node, in: sv) {
                controller.updateTrackedPose(pose)
            }
        }

        private func reset() {
            registered = false; dots = []; smoothedCenter = nil
            coffeeNode?.removeFromParentNode(); coffeeNode = nil; coffeePlane = nil
        }

        /// Track each dot by searching its seeded color near its last position.
        private func trackDots(frame: ARFrame) {
            let pb = frame.capturedImage
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb)
            let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
            let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
            let cRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let cPtr = cBase.assumingMemoryBound(to: UInt8.self)

            for i in dots.indices {
                let d = dots[i]
                var sumX: Float = 0, sumY: Float = 0, n = 0
                let cx = Int(d.img.x), cy = Int(d.img.y)
                var py = max(0, cy - searchHalf)
                while py < min(H, cy + searchHalf) {
                    var px = max(0, cx - searchHalf)
                    while px < min(W, cx + searchHalf) {
                        let co = (py / 2) * cRow + (px / 2) * 2
                        let cb = Float(cPtr[co]), cr = Float(cPtr[co + 1])
                        let dist = abs(cb - d.cb) + abs(cr - d.cr)
                        if dist < chromaTol { sumX += Float(px); sumY += Float(py); n += 1 }
                        px += 2
                    }
                    py += 2
                }
                if n >= 3 { dots[i].img = SIMD2<Float>(sumX / Float(n), sumY / Float(n)) }
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            _ = yBase   // (luma plane retained via lock; chroma drives the match)

            // Unproject the (updated) image positions to world via LiDAR depth.
            for i in dots.indices {
                if let w = worldPoint(atImagePx: dots[i].img, frame: frame) { dots[i].world = w }
            }
        }

        // MARK: - Sampling / geometry helpers

        private func imagePx(fromScreen tap: CGPoint, frame: ARFrame, viewport: CGSize) -> SIMD2<Float>? {
            let nv = CGPoint(x: tap.x / max(viewport.width, 1), y: tap.y / max(viewport.height, 1))
            let ni = nv.applying(frame.displayTransform(for: .portrait, viewportSize: viewport).inverted())
            guard ni.x >= 0, ni.x <= 1, ni.y >= 0, ni.y <= 1 else { return nil }
            let W = CVPixelBufferGetWidth(frame.capturedImage)
            let H = CVPixelBufferGetHeight(frame.capturedImage)
            return SIMD2<Float>(Float(ni.x) * Float(W), Float(ni.y) * Float(H))
        }

        private func chroma(at px: SIMD2<Float>, image pb: CVPixelBuffer) -> (Float, Float)? {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
            let cRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let cPtr = cBase.assumingMemoryBound(to: UInt8.self)
            let co = (Int(px.y) / 2) * cRow + (Int(px.x) / 2) * 2
            return (Float(cPtr[co]), Float(cPtr[co + 1]))
        }

        private func worldPoint(atImagePx px: SIMD2<Float>, frame: ARFrame) -> SIMD3<Float>? {
            guard let depth = frame.sceneDepth?.depthMap else { return nil }
            let imgW = CVPixelBufferGetWidth(frame.capturedImage)
            let imgH = CVPixelBufferGetHeight(frame.capturedImage)
            CVPixelBufferLockBaseAddress(depth, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
            let dW = CVPixelBufferGetWidth(depth), dH = CVPixelBufferGetHeight(depth)
            let dRow = CVPixelBufferGetBytesPerRow(depth)
            guard let dBase = CVPixelBufferGetBaseAddress(depth) else { return nil }
            let dpx = min(dW - 1, Int(px.x / Float(imgW) * Float(dW)))
            let dpy = min(dH - 1, Int(px.y / Float(imgH) * Float(dH)))
            let d = dBase.advanced(by: dpy * dRow).assumingMemoryBound(to: Float32.self)[dpx]
            guard d.isFinite, d > 0.05, d < 5 else { return nil }
            return unproject(px: px.x, py: px.y, depth: d, camera: frame.camera)
        }

        private func unproject(px: Float, py: Float, depth d: Float, camera: ARCamera) -> SIMD3<Float> {
            let K = camera.intrinsics
            let x = (px - K.columns.2.x) * d / K.columns.0.x
            let y = (py - K.columns.2.y) * d / K.columns.1.y
            let w = camera.transform * SIMD4<Float>(x, -y, -d, 1)
            return SIMD3<Float>(w.x, w.y, w.z)
        }

        private func centroid(_ p: [SIMD3<Float>]) -> SIMD3<Float> {
            p.reduce(SIMD3<Float>(repeating: 0), +) / Float(max(p.count, 1))
        }

        private func screenPoint(world c: SIMD3<Float>, in sv: ARSCNView) -> CGPoint {
            let s = sv.projectPoint(SCNVector3(c))
            return CGPoint(x: CGFloat(s.x), y: CGFloat(s.y))
        }

        private func projectedPose(of disc: SCNNode, in sv: ARSCNView) -> CupPose? {
            let c = disc.presentation.simdWorldPosition
            let r = lockedRadius * controller.radiusScale
            let sc = sv.projectPoint(SCNVector3(c))
            let sx = sv.projectPoint(SCNVector3(c + SIMD3<Float>(r, 0, 0)))
            let sz = sv.projectPoint(SCNVector3(c + SIMD3<Float>(0, 0, r)))
            let w = Float(max(sv.bounds.width, 1)), h = Float(max(sv.bounds.height, 1))
            guard sc.z > 0, sc.z < 1 else { return nil }
            let center = SIMD2<Float>(Float(sc.x) / w, Float(sc.y) / h)
            let ax = abs(Float(sx.x) - Float(sc.x)) / w
            let az = abs(Float(sz.y) - Float(sc.y)) / h
            return CupPose(center: center, axes: SIMD2<Float>(max(ax, 0.02), max(az, 0.02)),
                           angle: 0, confidence: 1)
        }
    }
}
