// TEMPORARY device harness — the on-camera counterpart to SimulationDebugView.
//
// This is the integration seam: it wires Ken's Sensor layer (AprilTagTracker +
// AprilTagPourSource) to Samuel's Simulation layer so the fluid sim is driven by
// the REAL pitcher and cup instead of touch or the scripted demo. It only
// CONSUMES the Sensor public API — it doesn't modify it.
//
// Kept deliberately minimal (live camera + the sim disc seated on the cup + a
// small status HUD). Replace with the real Presentation root (Ellie) when it
// lands; the ARSession-driving belongs in Sensor/Presentation long-term.

import ARKit
import SceneKit
import SwiftUI
import simd

/// Owns the Metal stack + the AprilTag source, is the `ARSession` delegate, and
/// turns each frame's tag detections into (a) a `PourSample` stream for the
/// controller and (b) a `CupPose` so the disc paints on the real cup.
final class CameraPourCoordinator: NSObject, ARSessionDelegate, ObservableObject {
    let controller: SimulationController
    let blitter: FluidBlitter

    private let tracker: AprilTagTracker?
    private let source = AprilTagPourSource()

    // HUD status — written only on the main thread (see `ingest`).
    @Published private(set) var cupDetected = false
    @Published private(set) var pitcherTagCount = 0
    @Published private(set) var trackerReady = false

    /// View size used to project cup geometry into normalized view space; set by
    /// the representable on layout.
    var viewportSize: CGSize = .zero

    // Keep the disc visible for a short beat after the cup was last seen, so a
    // one-frame tag dropout doesn't blink it off.
    private var lastCupSeenTime: TimeInterval = 0
    private let discHoldSeconds: TimeInterval = 0.3

    init?(context: MetalContext) {
        guard let sim = FluidSimulation(context: context),
              let blitter = FluidBlitter(context: context) else { return nil }
        let controller = SimulationController(sim: sim)
        blitter.controller = controller
        self.controller = controller
        self.blitter = blitter
        self.tracker = try? AprilTagTracker()
        super.init()
        trackerReady = (tracker != nil)
        blitter.drawsDisc = false            // stay hidden until a cup is tracked
        controller.attach(source: source)    // same push path touch/demo use
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let tracker else { return }
        // ARKit camera-local axes are X-right, Y-up, Z-backward; the cup's
        // in-plane basis wants camera-right and camera-DOWN in world space.
        let m = frame.camera.transform
        let right = simd_normalize(SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        let down  = -simd_normalize(SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z))
        let camera = frame.camera
        let time = frame.timestamp
        // `process` drops frames while a detection is in flight and calls back
        // on the main thread; everything downstream of here is main-thread.
        tracker.process(frame: frame) { [weak self] world in
            self?.ingest(world: world, camera: camera, right: right, down: down, time: time)
        }
    }

    // MARK: - Detection → geometry → source (main thread)

    private func ingest(world: [Int: SIMD3<Float>], camera: ARCamera,
                        right: SIMD3<Float>, down: SIMD3<Float>, time: TimeInterval) {
        // Cup circle from the 3 rim tags, fixed order (never detection order).
        let ids = AprilTagRoles.cupTagIDs
        var cup: CupGeometry?
        if let a = world[ids[0]], let b = world[ids[1]], let c = world[ids[2]] {
            cup = CupGeometry.fromCupTags(a: a, b: b, c: c, cameraRight: right, cameraDown: down)
        }

        // Pitcher tags (spout + back), whichever are visible this frame.
        var pitcher: [Int: SIMD3<Float>] = [:]
        if let s = world[AprilTagRoles.pitcherSpoutID] { pitcher[AprilTagRoles.pitcherSpoutID] = s }
        if let b = world[AprilTagRoles.pitcherBackID]  { pitcher[AprilTagRoles.pitcherBackID]  = b }

        // Drive Ken's source exactly as it expects: called every processed frame,
        // it handles occlusion/grace and emits the PourSample the controller cached.
        source.update(pitcherWorldPoints: pitcher, cup: cup, time: time)

        // Seat the sim disc on the real cup.
        if let cup, viewportSize.width > 1,
           let pose = Self.cupPose(from: cup, camera: camera, viewport: viewportSize) {
            blitter.cupPose = pose
        }

        // Show the disc only while the cup is (recently) tracked.
        if cup != nil { lastCupSeenTime = time }
        blitter.drawsDisc = (time - lastCupSeenTime) <= discHoldSeconds

        cupDetected = (cup != nil)
        pitcherTagCount = pitcher.count
    }

    /// Project the cup's world circle onto the screen as a `CupPose` ellipse.
    /// Approximation: sample the two conjugate semi-diameters along the cup's own
    /// in-plane basis and use them as the ellipse axes. Exact only when they
    /// project perpendicular (near-top-down — our tripod case); good enough to
    /// seat the disc for this mock. A precise conic fit is a Presentation concern.
    static func cupPose(from cup: CupGeometry, camera: ARCamera, viewport: CGSize) -> CupPose? {
        func project(_ p: SIMD3<Float>) -> SIMD2<Float> {
            let cg = camera.projectPoint(p, orientation: .portrait, viewportSize: viewport)
            return SIMD2<Float>(Float(cg.x) / Float(viewport.width),
                                Float(cg.y) / Float(viewport.height))
        }
        let c  = project(cup.center)
        let su = project(cup.center + cup.radius * cup.basisU) - c
        let sv = project(cup.center + cup.radius * cup.basisV) - c
        let ax = simd_length(su)
        let ay = simd_length(sv)
        guard ax > 1e-4, ay > 1e-4, ax < 2, ay < 2 else { return nil }
        return CupPose(center: c, axes: SIMD2<Float>(ax, ay),
                       angle: atan2(su.y, su.x), confidence: 1)
    }
}

/// Hosts an `ARSCNView` — it renders the live camera automatically and owns the
/// `ARSession` we tap for frames. The transparent sim layer sits above it.
struct ARCameraContainer: UIViewRepresentable {
    let coordinator: CameraPourCoordinator

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.session.delegate = coordinator
        v.automaticallyUpdatesLighting = true
        if ARWorldTrackingConfiguration.isSupported {
            v.session.run(ARWorldTrackingConfiguration())
        }
        return v
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        coordinator.viewportSize = uiView.bounds.size
    }
}

/// The mock screen: live camera, the fluid disc composited on the tracked cup,
/// and a status HUD so you can see the sensor feeding the sim.
struct CameraPourView: View {
    @StateObject private var coordinator: CameraPourCoordinator

    init() {
        // Metal + Simulation stack is always available on device; if it can't
        // build there's nothing this view could show anyway.
        _coordinator = StateObject(wrappedValue: CameraPourCoordinator(context: MetalContext()!)!)
    }

    var body: some View {
        ZStack {
            ARCameraContainer(coordinator: coordinator)
                .ignoresSafeArea()
            SimulationView(blitter: coordinator.blitter, transparent: true)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack {
                CameraStatusHUD(coordinator: coordinator)
                Spacer()
            }
            .padding()
        }
    }
}

/// Small translucent readout: is the cup seen, how many pitcher tags, and the
/// live physics the sensor is producing.
private struct CameraStatusHUD: View {
    @ObservedObject var coordinator: CameraPourCoordinator
    @ObservedObject var controller: SimulationController

    init(coordinator: CameraPourCoordinator) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _controller = ObservedObject(wrappedValue: coordinator.controller)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !coordinator.trackerReady {
                Text("⚠︎ AprilTag detector failed to init")
            }
            Text(coordinator.cupDetected ? "Cup ● tracked" : "Cup ○ searching…")
            Text("Pitcher: \(coordinator.pitcherTagCount)/2 tags")
            Text(String(format: "Fill %.0f%%   %@",
                        controller.fillFraction * 100,
                        String(describing: controller.phase)))
            Text(String(format: "φ %.2f   Fr %.2f", controller.stats.phi, controller.stats.froude))
        }
        .font(.system(.footnote, design: .monospaced))
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
