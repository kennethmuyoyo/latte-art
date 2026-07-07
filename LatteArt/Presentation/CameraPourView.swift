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
    /// `false` only when the spout tag IS seen but sits outside the rim — the
    /// pour is suppressed (water would miss the cup). Distinct from "spout not
    /// detected" (that shows as a lower `pitcherTagCount`).
    @Published private(set) var spoutOverCup = true
    /// The detected cup as an on-screen circle for the SwiftUI guide ring.
    @Published private(set) var cupRing: CupRing? = nil

    struct CupRing: Equatable { var center: CGPoint; var radius: CGFloat }

    /// View size used to project cup geometry into normalized view space; set by
    /// the representable on layout.
    var viewportSize: CGSize = .zero

    // Keep the disc + ring visible for a short beat after the cup was last
    // placed, so a one-frame tag dropout doesn't blink them off.
    private var lastCupSeenTime: TimeInterval = 0
    private var lastRing: CupRing?
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

        // Suppress the pour when the spout is over the table, not the cup mouth.
        // We already hold the real spout position AND the cup circle here (before
        // the source clamps anything), so we can just test whether the spout
        // projects inside the rim. If it's outside, drop the spout so the source
        // ends the pour (water misses the cup → no deposit) while the cup stays
        // tracked — the disc/ring keep showing, only the pouring stops.
        var offCup = false
        var pourPitcher = pitcher
        if let cup, let spout = pitcher[AprilTagRoles.pitcherSpoutID],
           !CupSpace.isInside(cup.cupUV(of: spout)) {
            pourPitcher[AprilTagRoles.pitcherSpoutID] = nil
            offCup = true
        }

        // Drive Ken's source exactly as it expects: called every processed frame,
        // it handles occlusion/grace and emits the PourSample the controller cached.
        source.update(pitcherWorldPoints: pourPitcher, cup: cup, time: time)

        // Seat the sim disc + guide ring on the real cup. Only count the cup as
        // placeable when the projection succeeds AND is sane — a near-collinear
        // tag layout (e.g. the 3 cup tags in a row on a flat test sheet) yields a
        // degenerate/huge circle, which we hide rather than paint over the feed.
        var ring: CupRing? = nil
        if let cup, viewportSize.width > 1,
           let pose = Self.cupPose(from: cup, camera: camera, viewport: viewportSize) {
            blitter.cupPose = pose
            ring = CupRing(
                center: CGPoint(x: CGFloat(pose.center.x) * viewportSize.width,
                                y: CGFloat(pose.center.y) * viewportSize.height),
                radius: CGFloat(pose.axes.x) * viewportSize.width)
        }

        // Show the disc + ring only while a valid placement is (recently) available.
        if let ring { lastRing = ring; lastCupSeenTime = time }
        let visible = (time - lastCupSeenTime) <= discHoldSeconds
        blitter.drawsDisc = visible

        cupRing = visible ? lastRing : nil
        cupDetected = (cup != nil)
        pitcherTagCount = pitcher.count
        spoutOverCup = !offCup
    }

    /// Project the cup's world circle onto the screen and pack it into a
    /// `CupPose` the blitter renders as an aspect-correct pixel circle.
    ///
    /// The blitter maps `axes` to clip space as `(2·ax, 2·ay)`, i.e. a pixel
    /// ellipse `(ax·W, ay·H)`. To draw a true circle of pixel radius `r` in a
    /// non-square (full-screen portrait) view we must therefore set
    /// `axes = (r/W, r/H)` — otherwise equal axes render as a tall oval. We
    /// approximate the (mildly elliptical) perspective view of the tilted rim
    /// as a circle whose radius is the mean of the two projected semi-diameters;
    /// a precise conic fit is a Presentation concern.
    static func cupPose(from cup: CupGeometry, camera: ARCamera, viewport: CGSize) -> CupPose? {
        let w = Float(viewport.width), h = Float(viewport.height)
        guard w > 1, h > 1 else { return nil }
        func px(_ p: SIMD3<Float>) -> SIMD2<Float> {
            let cg = camera.projectPoint(p, orientation: .portrait, viewportSize: viewport)
            return SIMD2<Float>(Float(cg.x), Float(cg.y))   // pixels, y-down
        }
        let cPx = px(cup.center)
        let rU = simd_length(px(cup.center + cup.radius * cup.basisU) - cPx)
        let rV = simd_length(px(cup.center + cup.radius * cup.basisV) - cPx)
        let rPx = 0.5 * (rU + rV)
        // Reject nonsense: sub-pixel, or bigger than the screen (degenerate /
        // near-collinear tags → huge circumcircle).
        guard rPx > 2, rPx < max(w, h) else { return nil }
        return CupPose(center: SIMD2<Float>(cPx.x / w, cPx.y / h),
                       axes: SIMD2<Float>(rPx / w, rPx / h),
                       angle: 0, confidence: 1)
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
            // Guide ring: outlines the detected cup rim so alignment is easy to
            // judge while testing tag sizes/placement. Same center/radius the
            // Metal disc uses, drawn full-screen to match the projection space.
            GeometryReader { _ in
                if let ring = coordinator.cupRing {
                    Circle()
                        .stroke(Color.cyan.opacity(0.9), lineWidth: 2)
                        .frame(width: ring.radius * 2, height: ring.radius * 2)
                        .position(ring.center)
                }
            }
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
            if !coordinator.spoutOverCup {
                Text("Spout off-cup — pour paused")
            }
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
