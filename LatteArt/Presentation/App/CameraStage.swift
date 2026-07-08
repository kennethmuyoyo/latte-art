import SwiftUI
import simd
#if !targetEnvironment(simulator)
import ARKit
import SceneKit
#endif

// The persistent "stage": the live camera + the Metal fluid disc that sit behind
// EVERY screen (the user's "camera almost always on" requirement). It owns the
// Metal/Simulation stack for the whole session and unifies two input paths:
//
//   • Device    — ARKit live feed + AprilTag pitcher/cup tracking (landscape).
//   • Simulator — a neutral backdrop + a centered virtual cup driven by touch.
//
// It CONSUMES the Sensor + Simulation public APIs only (SimulationController,
// FluidSimulation, FluidBlitter, SimulationView, AprilTag*/TouchPourSource); it
// never edits those layers. It is the Presentation-side replacement for the
// temporary CameraPourView / SimulationDebugView harnesses.
final class CameraStage: NSObject, ObservableObject {
    let controller: SimulationController
    let blitter: FluidBlitter

    /// Where the cup sits on screen (normalized view space, y-down). Shared by
    /// the fluid disc AND every CoreGraphics overlay so they register by
    /// construction. On device it's the projected AprilTag cup; in the Simulator
    /// it's a centered, aspect-correct virtual cup.
    @Published private(set) var cupViewPose: CupPose = .centeredDefault
    /// True when a usable cup is present (real detection on device; always true
    /// for the Simulator's virtual cup).
    @Published private(set) var cupDetected = false
    /// Pitcher tags seen this frame (device HUD / calibration hints). 0 in Simulator.
    @Published private(set) var pitcherTagCount = 0
    /// False only when the spout is seen but sits outside the rim (pour suppressed).
    @Published private(set) var spoutOverCup = true

    /// View size used to place the cup; set by the root on layout.
    var viewportSize: CGSize = .zero {
        didSet { if viewportSize != oldValue { viewportDidChange() } }
    }

    /// Whether the coffee disc should paint this phase (off during setup/framing,
    /// on during practice/result). Combined with cup validity on device.
    private var coffeeVisible = false

    // MARK: Metal + input wiring

    #if targetEnvironment(simulator)
    let touchSource = TouchPourSource()
    #else
    private let tracker: AprilTagTracker?
    private let source = AprilTagPourSource()
    private var lastCupSeenTime: TimeInterval = 0
    private var lastPose: CupPose?
    private let discHoldSeconds: TimeInterval = 0.3
    #endif

    /// Failable factory — the Metal stack can fail to build. (A failable `init?`
    /// can't override `NSObject.init()`, so construction goes through here.)
    static func make() -> CameraStage? {
        guard let ctx = MetalContext(),
              let sim = FluidSimulation(context: ctx),
              let blitter = FluidBlitter(context: ctx) else { return nil }
        let controller = SimulationController(sim: sim)
        blitter.controller = controller
        return CameraStage(controller: controller, blitter: blitter)
    }

    private init(controller: SimulationController, blitter: FluidBlitter) {
        self.controller = controller
        self.blitter = blitter
        #if !targetEnvironment(simulator)
        self.tracker = try? AprilTagTracker()
        #endif
        super.init()
        blitter.drawsDisc = false
        #if targetEnvironment(simulator)
        controller.attach(source: touchSource)
        #else
        controller.attach(source: source)
        #endif
    }

    // MARK: Phase control (called by the app flow)

    /// Show/hide the simulated coffee disc for the current phase.
    func setCoffeeVisible(_ visible: Bool) {
        coffeeVisible = visible
        refreshDiscVisibility()
    }

    /// Clear the fluid + fill for a fresh attempt.
    func reset() { controller.requestReset() }

    /// The pour sample the active source is producing right now (for the practice
    /// on-track/wrong feedback). `nil` when nothing is being poured.
    var currentPour: PourSample? {
        #if targetEnvironment(simulator)
        return touchSource.current
        #else
        return source.current
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Headless verification hook: drive the scripted circular pour so the coffee
    /// disc fills for screenshots without touch injection. Debug + Simulator only.
    func startScriptedPour() {
        controller.attach(source: AutoPourSource())
        setCoffeeVisible(true)
    }
    #endif

    private func refreshDiscVisibility() {
        #if targetEnvironment(simulator)
        blitter.drawsDisc = coffeeVisible
        #else
        blitter.drawsDisc = coffeeVisible && cupDetected
        #endif
    }

    // MARK: Touch input (Simulator)

    /// Feed a screen-space touch (Simulator virtual cup). No-op on device.
    func touch(atViewPoint p: CGPoint, viewport: CGSize) {
        #if targetEnvironment(simulator)
        guard viewport.width > 1, viewport.height > 1 else { return }
        let n = SIMD2<Float>(Float(p.x / viewport.width), Float(p.y / viewport.height))
        touchSource.start()
        touchSource.touchMoved(toUV: cupViewPose.cupUV(fromViewPoint: n))
        #endif
    }

    func touchEnded() {
        #if targetEnvironment(simulator)
        touchSource.end()
        #endif
    }

    // MARK: Cup placement

    private func viewportDidChange() {
        #if targetEnvironment(simulator)
        // Center a virtual cup, aspect-corrected so the disc renders as a true
        // circle (blitter maps axes to pixels as (ax·W, ay·H)).
        let w = Float(viewportSize.width), h = Float(viewportSize.height)
        guard w > 1, h > 1 else { return }
        let r = 0.3 * min(w, h)
        let pose = CupPose(center: [0.5, 0.5], axes: [r / w, r / h], angle: 0, confidence: 1)
        cupViewPose = pose
        blitter.cupPose = pose
        cupDetected = true
        #endif
    }
}

// MARK: - Background view

extension CameraStage {
    /// The always-on background: live camera + fluid disc on device; a neutral
    /// backdrop + centered fluid disc in the Simulator.
    @ViewBuilder
    func backgroundView() -> some View {
        ZStack {
            #if targetEnvironment(simulator)
            SimulatorBackdrop()
            #else
            ARCameraContainer(stage: self)
            #endif
            SimulationView(blitter: blitter, transparent: true)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

/// A calm neutral backdrop for the Simulator (no camera/ARKit there).
private struct SimulatorBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x2A2724), Color(hex: 0x14110F)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text("Simulator — camera unavailable")
                .appText(.small)
                .foregroundStyle(Palette.onCameraFaint)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 10)
        }
        .ignoresSafeArea()
    }
}

#if !targetEnvironment(simulator)
// MARK: - Device: ARKit camera + AprilTag ingest (landscape)

/// Hosts an `ARSCNView` (renders the live camera automatically) and makes the
/// stage its session delegate. Lifted from the temporary `CameraPourView`; the
/// only substantive change is the landscape projection orientation.
private struct ARCameraContainer: UIViewRepresentable {
    let stage: CameraStage
    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.session.delegate = stage
        v.automaticallyUpdatesLighting = true
        if ARWorldTrackingConfiguration.isSupported {
            v.session.run(ARWorldTrackingConfiguration())
        }
        return v
    }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

extension CameraStage: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let tracker else { return }
        let m = frame.camera.transform
        let right = simd_normalize(SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        let down = -simd_normalize(SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z))
        let camera = frame.camera
        let time = frame.timestamp
        tracker.process(frame: frame) { [weak self] world in
            self?.ingest(world: world, camera: camera, right: right, down: down, time: time)
        }
    }

    private func ingest(world: [Int: SIMD3<Float>], camera: ARCamera,
                        right: SIMD3<Float>, down: SIMD3<Float>, time: TimeInterval) {
        let ids = AprilTagRoles.cupTagIDs
        var cup: CupGeometry?
        if let a = world[ids[0]], let b = world[ids[1]], let c = world[ids[2]] {
            cup = CupGeometry.fromCupTags(a: a, b: b, c: c, cameraRight: right, cameraDown: down)
        }

        var pitcher: [Int: SIMD3<Float>] = [:]
        if let s = world[AprilTagRoles.pitcherSpoutID] { pitcher[AprilTagRoles.pitcherSpoutID] = s }
        if let b = world[AprilTagRoles.pitcherBackID] { pitcher[AprilTagRoles.pitcherBackID] = b }

        // Suppress the pour when the spout is over the table, not the cup mouth.
        var offCup = false
        var pourPitcher = pitcher
        if let cup, let spout = pitcher[AprilTagRoles.pitcherSpoutID],
           !CupSpace.isInside(cup.cupUV(of: spout)) {
            pourPitcher[AprilTagRoles.pitcherSpoutID] = nil
            offCup = true
        }
        source.update(pitcherWorldPoints: pourPitcher, cup: cup, time: time)

        // Project the cup circle to a screen-space CupPose (landscape).
        var pose: CupPose?
        if let cup, viewportSize.width > 1,
           let p = Self.cupPose(from: cup, camera: camera, viewport: viewportSize) {
            pose = p
        }
        if let pose { lastPose = pose; lastCupSeenTime = time }
        let visible = (time - lastCupSeenTime) <= discHoldSeconds

        if let lastPose, visible {
            blitter.cupPose = lastPose
            cupViewPose = lastPose
        }
        cupDetected = visible
        pitcherTagCount = pitcher.count
        spoutOverCup = !offCup
        refreshDiscVisibility()
    }

    /// Project the cup's world circle to a screen CupPose. Landscape orientation
    /// (the temporary CameraPourView used `.portrait`). Approximates the tilted
    /// rim as a circle of the mean projected radius.
    static func cupPose(from cup: CupGeometry, camera: ARCamera, viewport: CGSize) -> CupPose? {
        let w = Float(viewport.width), h = Float(viewport.height)
        guard w > 1, h > 1 else { return nil }
        func px(_ p: SIMD3<Float>) -> SIMD2<Float> {
            let cg = camera.projectPoint(p, orientation: .landscapeRight, viewportSize: viewport)
            return SIMD2<Float>(Float(cg.x), Float(cg.y))
        }
        let cPx = px(cup.center)
        let rU = simd_length(px(cup.center + cup.radius * cup.basisU) - cPx)
        let rV = simd_length(px(cup.center + cup.radius * cup.basisV) - cPx)
        let rPx = 0.5 * (rU + rV)
        guard rPx > 2, rPx < max(w, h) else { return nil }
        return CupPose(center: SIMD2<Float>(cPx.x / w, cPx.y / h),
                       axes: SIMD2<Float>(rPx / w, rPx / h),
                       angle: 0, confidence: 1)
    }
}
#endif
