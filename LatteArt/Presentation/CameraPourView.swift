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
    /// The detected cup as an on-screen ellipse for the SwiftUI guide ring —
    /// the true projected shape (see `cupPose(from:)`), not a forced circle.
    @Published private(set) var cupRing: CupRing? = nil
    /// DEBUG: distinguishes "3D circle math failed" (no cup transforms /
    /// degenerate triangle) from "2D screen projection failed" (cupPose(from:)
    /// returned nil despite a valid 3D circle) — same top-line `cupDetected`
    /// symptom, different cause. Also mirrors `blitter.drawsDisc` so the HUD
    /// can show it without reaching into a non-@Published class property.
    @Published private(set) var debugLine = "—"
    @Published private(set) var discDrawing = false

    struct CupRing: Equatable {
        var center: CGPoint
        var semiAxes: CGSize      // (semi-major, semi-minor), pixels
        var angleRadians: Double  // y-down view space, matches CupPose.angle
    }

    /// View size used to project cup geometry into normalized view space; set by
    /// the representable on layout.
    var viewportSize: CGSize = .zero

    // Keep the disc + ring visible for a short beat after the cup was last
    // placed, so a one-frame tag dropout doesn't blink them off.
    private var lastCupSeenTime: TimeInterval = 0
    private var lastRing: CupRing?
    private let discHoldSeconds: TimeInterval = 0.3

    // Smoothed screen-space cup center + conjugate-diameter vectors feeding
    // `cupPose(from:)` — see that method's doc comment. The center needs its
    // own smoothing distinct from p/q's: p/q only affect the ellipse's
    // shape/rotation, but raw per-frame noise in the 3D cup-center estimate
    // (from AprilTag pose noise, amplified further whenever `CupRegistration`
    // re-derives it) shows up as the whole ring visibly floating/jittering
    // around, independent of any rotation issue.
    private var smoothedCenter: SIMD2<Float>?
    private var smoothedP: SIMD2<Float>?
    private var smoothedQ: SIMD2<Float>?

    /// Captured the moment all 3 cup tags are seen together; lets the cup
    /// keep tracking from just 1 or 2 of them afterward (see `CupRegistration`).
    /// Refreshed every frame all 3 ARE visible, so it self-corrects rather
    /// than locking in a single early (possibly noisy) snapshot.
    private var cupRegistration: CupRegistration?

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

    private func ingest(world: [Int: simd_float4x4], camera: ARCamera,
                        right: SIMD3<Float>, down: SIMD3<Float>, time: TimeInterval) {
        func position(_ t: simd_float4x4) -> SIMD3<Float> {
            SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        }

        // Cup circle from the 3 rim tags, fixed order (never detection order).
        let ids = AprilTagRoles.cupTagIDs
        var cupTagTransforms: [Int: simd_float4x4] = [:]
        for id in ids { if let t = world[id] { cupTagTransforms[id] = t } }

        var cup: CupGeometry?
        if let a = world[ids[0]], let b = world[ids[1]], let c = world[ids[2]] {
            cup = CupGeometry.fromCupTags(a: position(a), b: position(b), c: position(c),
                                          cameraRight: right, cameraDown: down)
            // All 3 visible: (re)capture the registration fresh every time —
            // self-correcting, and keeps it current if the rig gets nudged.
            if let cup { cupRegistration = CupRegistration(cup: cup, tagWorldTransforms: cupTagTransforms) }
        }
        if cup == nil, let reg = cupRegistration, !cupTagTransforms.isEmpty,
           let recon = reg.reconstruct(from: cupTagTransforms) {
            // Fewer than 3 visible, but at least 1 registered tag is — keep
            // tracking from the cached rigid relationship instead of losing
            // the cup entirely (see CupRegistration's doc comment).
            cup = CupGeometry.from(center: recon.center, radius: recon.radius, normal: recon.normal,
                                   cameraRight: right, cameraDown: down)
        }

        // Pitcher tags (spout + whichever tilt-reference tags are visible)
        // — full transforms preserved (not just position), so the source
        // can pick the best-conditioned reference, or fall back to a single
        // tag's own orientation for tilt if none are visible at all (see
        // AprilTagPourSource.tilt).
        var pitcher: [Int: simd_float4x4] = [:]
        if let s = world[AprilTagRoles.pitcherSpoutID] { pitcher[AprilTagRoles.pitcherSpoutID] = s }
        for refID in AprilTagRoles.pitcherReferenceIDs {
            if let t = world[refID] { pitcher[refID] = t }
        }

        // Suppress the pour when the spout is over the table, not the cup mouth.
        // We already hold the real spout position AND the cup circle here (before
        // the source clamps anything), so we can just test whether the spout
        // projects inside the rim. If it's outside, drop the spout so the source
        // ends the pour (water misses the cup → no deposit) while the cup stays
        // tracked — the disc/ring keep showing, only the pouring stops.
        var offCup = false
        var pourPitcher = pitcher
        if let cup, let spoutTransform = pitcher[AprilTagRoles.pitcherSpoutID],
           !CupSpace.isInside(cup.cupUV(of: position(spoutTransform))) {
            pourPitcher[AprilTagRoles.pitcherSpoutID] = nil
            offCup = true
        }

        // The pitcher only occludes the disc where it's ACTUALLY closer to the
        // camera than the cup surface is — a real depth test, not "a tag is
        // visible". Uses `pitcher` (pre-pour-suppression): the pitcher is
        // still physically there even when pouring itself is suppressed.
        // `FluidBlitter`/the shader only have 2 occlusion slots — with up to
        // 3 pitcher tags now (spout + 2 reference tags), cap defensively
        // rather than relying on FluidBlitter silently dropping the rest.
        var occluders: [Occluder] = []
        if let cup {
            let cameraPos = position(camera.transform)
            let tagSize = Float(AprilTagRoles.pitcherTagSizeMeters)
            for (_, transform) in pitcher {
                if let occluder = Self.occluder(forTag: position(transform), tagSizeMeters: tagSize,
                                                cameraPos: cameraPos, cup: cup) {
                    occluders.append(occluder)
                }
            }
        }
        blitter.occluders = Array(occluders.prefix(2))

        // Drive Ken's source exactly as it expects: called every processed frame,
        // it handles occlusion/grace and emits the PourSample the controller cached.
        source.update(pitcherWorldTransforms: pourPitcher, cup: cup, time: time)

        // Seat the sim disc + guide ring on the real cup. Only count the cup as
        // placeable when the projection succeeds AND is sane — a near-collinear
        // tag layout (e.g. the 3 cup tags in a row on a flat test sheet) yields a
        // degenerate/huge circle, which we hide rather than paint over the feed.
        var ring: CupRing? = nil
        if cup == nil {
            // Only reset the ellipse smoothing once the cup has actually been
            // lost for a while (same grace window `discHoldSeconds` already
            // uses to keep the disc itself visible) — NOT on every single
            // nil frame. Real tag detection flickers for a frame or two
            // constantly during an actual pour (the pitcher/hand briefly
            // occludes a rim tag); resetting on every one of those blips
            // meant tracking resumed from a raw, unsmoothed reading each
            // time, which looked exactly like the disc snapping/jumping —
            // worse the longer a practice session runs, since there are more
            // chances for a blip. A real, sustained loss still resets so a
            // later re-detection snaps to the fresh reading instead of
            // drifting in from a stale, possibly far-away smoothed value.
            if time - lastCupSeenTime > discHoldSeconds {
                smoothedCenter = nil
                smoothedP = nil
                smoothedQ = nil
            }
            debugLine = cupRegistration == nil
                ? "no 3D circle yet (need all 3 cup tags + non-collinear, once)"
                : "no cup tags visible at all (registered, but none in view)"
        } else if viewportSize.width <= 1 {
            debugLine = "viewport not laid out yet (\(viewportSize))"
        }
        if let cup, viewportSize.width > 1 {
            if let pose = cupPose(from: cup, camera: camera, viewport: viewportSize) {
                blitter.cupPose = pose
                let r = CupRing(
                    center: CGPoint(x: CGFloat(pose.center.x) * viewportSize.width,
                                    y: CGFloat(pose.center.y) * viewportSize.height),
                    semiAxes: CGSize(width: CGFloat(pose.axes.x) * viewportSize.width,
                                     height: CGFloat(pose.axes.y) * viewportSize.height),
                    angleRadians: Double(pose.angle))
                ring = r
                debugLine = String(format: "ring c(%.0f,%.0f) a(%.0f,%.0f)px θ%.0f°",
                                   r.center.x, r.center.y,
                                   r.semiAxes.width, r.semiAxes.height,
                                   r.angleRadians * 180 / .pi)
            } else {
                debugLine = "3D circle OK, cupPose(from:) rejected it (nil)"
            }
        }

        // Show the disc + ring only while a valid placement is (recently) available.
        if let ring { lastRing = ring; lastCupSeenTime = time }
        let visible = (time - lastCupSeenTime) <= discHoldSeconds
        blitter.drawsDisc = visible
        discDrawing = visible

        cupRing = visible ? lastRing : nil
        cupDetected = (cup != nil)
        pitcherTagCount = pitcher.count
        spoutOverCup = !offCup

        // TEMPORARY: surface why placement did/didn't happen.
        let vp = String(format: "vp %.0f×%.0f", viewportSize.width, viewportSize.height)
        let rad = cup.map { String(format: " R%.3fm", $0.radius) } ?? " R—"
        debug = vp + rad + (ring != nil ? " ok" : " noplace")
    }

    /// A REAL depth test, not a guess: is this tag genuinely closer to the
    /// camera than the cup surface is, at the screen location where the tag
    /// currently projects? Both distances come from data we already have —
    /// the tag's own position (from AprilTag pose estimation, which already
    /// solved for it from the tag's known physical size and its projected
    /// size/shape in the image) and the cup's actual tracked plane — no
    /// guessing, no LiDAR needed.
    ///
    /// Method: cast the ray from the camera through the tag's position, and
    /// intersect it with the cup's plane (`center`, `normal`). That
    /// intersection point is "where the cup surface is, along the same
    /// direction the tag is in" — its distance from the camera is the cup
    /// surface's depth at that screen location. If the tag's own distance is
    /// smaller, the tag (and by extension the pitcher it's mounted on) is
    /// really in front of the surface there, and should occlude it.
    ///
    /// The hole's radius comes from `tagSizeMeters` (the tag's real physical
    /// size), scaled by `pitcherBodyToTagRatio` (the pitcher body is wider
    /// than just the tag glued to it) and converted into cup-UV units via the
    /// cup's own known radius — a measured quantity, not an arbitrary guess.
    private static let pitcherBodyToTagRatio: Float = 3.0

    private static func occluder(forTag tagPos: SIMD3<Float>, tagSizeMeters: Float,
                                  cameraPos: SIMD3<Float>, cup: CupGeometry) -> Occluder? {
        let toTag = tagPos - cameraPos
        let tagDepth = simd_length(toTag)
        guard tagDepth > 1e-4 else { return nil }
        let rayDir = toTag / tagDepth

        let denom = simd_dot(rayDir, cup.normal)
        guard abs(denom) > 1e-5 else { return nil }   // ray parallel to the cup plane — no meaningful intersection
        let cupSurfaceDepth = simd_dot(cup.center - cameraPos, cup.normal) / denom
        guard cupSurfaceDepth > 0 else { return nil }  // plane is behind the camera along this ray

        guard tagDepth < cupSurfaceDepth else { return nil }  // tag is NOT closer than the surface here — don't occlude

        let bodyRadiusMeters = tagSizeMeters * pitcherBodyToTagRatio
        let radiusUV = (bodyRadiusMeters / max(cup.radius, 1e-4)) * CupSpace.radius
        return Occluder(uv: cup.cupUV(of: tagPos), radius: radiusUV)
    }

    /// Project the cup's world circle onto the screen and pack it into a
    /// `CupPose` the blitter renders as the TRUE projected ellipse — a circle
    /// viewed at an angle (any angle other than dead-on from directly above)
    /// projects as a genuine ellipse, not a circle, and forcing a circle is
    /// exactly what made the disc look wrong/misaligned against the real cup.
    ///
    /// Method: `p = proj(center + r·basisU) − proj(center)` and
    /// `q = proj(center + r·basisV) − proj(center)` are two CONJUGATE
    /// semi-diameters of the projected ellipse — i.e. the map
    /// `θ ↦ p·cosθ + q·sinθ` traces that ellipse exactly (this holds for any
    /// camera model, since it's just linear algebra on two fixed 2D vectors,
    /// not an approximation specific to perspective projection). Writing
    /// `M = [p q]` (p, q as columns), the map is `M · (cosθ, sinθ)`, i.e. `M`
    /// applied to the unit circle — so the ellipse's true semi-axes are the
    /// singular values of `M`, and their directions are `M`'s left singular
    /// vectors. For a 2x2 `M` those come from eigendecomposing the symmetric
    /// `M·Mᵗ` (closed-form for a 2x2, no general SVD needed).
    ///
    /// `p`/`q` are smoothed (EMA) across frames before the fit: raw per-frame
    /// tag noise made the fitted angle unstable, worst exactly when the cup
    /// is viewed close to top-down (semi-major ≈ semi-minor), because the
    /// eigenvector direction is ill-conditioned right at that point — tiny
    /// noise flips or swings the angle wildly even though the cup hasn't
    /// moved, which visibly dragged the pour target to a different screen
    /// spot frame to frame. Smoothing the raw vectors (not the derived angle)
    /// sidesteps the angle's own 180°-ambiguity wraparound entirely.
    func cupPose(from cup: CupGeometry, camera: ARCamera, viewport: CGSize) -> CupPose? {
        let w = Float(viewport.width), h = Float(viewport.height)
        guard w > 1, h > 1 else { return nil }
        func px(_ p: SIMD3<Float>) -> SIMD2<Float> {
            // App is locked to a single landscape orientation (see
            // Info.plist / project.yml) — the projection orientation must
            // match what's actually on screen, or points land rotated 90°.
            let cg = camera.projectPoint(p, orientation: .landscapeRight, viewportSize: viewport)
            return SIMD2<Float>(Float(cg.x), Float(cg.y))   // pixels, y-down
        }
        let rawCenter = px(cup.center)
        let rawP = px(cup.center + cup.radius * cup.basisU) - rawCenter
        let rawQ = px(cup.center + cup.radius * cup.basisV) - rawCenter
        let smoothing: Float = 0.25
        let cPx = smoothedCenter.map { $0 + smoothing * (rawCenter - $0) } ?? rawCenter
        let p = smoothedP.map { $0 + smoothing * (rawP - $0) } ?? rawP
        let q = smoothedQ.map { $0 + smoothing * (rawQ - $0) } ?? rawQ
        smoothedCenter = cPx
        smoothedP = p
        smoothedQ = q

        // Symmetric 2x2 M·Mᵗ = [[a, b], [b, d]] where M = [p q].
        let a = p.x * p.x + q.x * q.x
        let b = p.x * p.y + q.x * q.y
        let d = p.y * p.y + q.y * q.y
        let tr = a + d, det = a * d - b * b
        let disc = max(tr * tr / 4 - det, 0).squareRoot()
        let lambdaMax = tr / 2 + disc
        let lambdaMin = max(tr / 2 - disc, 0)
        let semiMajorPx = lambdaMax.squareRoot()
        let semiMinorPx = lambdaMin.squareRoot()
        // Eigenvector of M·Mᵗ for lambdaMax, i.e. the major-axis direction in
        // pixels: (M·Mᵗ − λI)v = 0 → v ∝ (b, λ−a) (or (λ−d, b); use whichever
        // has the larger magnitude component for numerical stability).
        let angle: Float
        if abs(b) > 1e-6 || abs(lambdaMax - a) > 1e-6 {
            angle = atan2(lambdaMax - a, b)
        } else {
            // (b, lambdaMax-a) is ~(0,0) — the atan2 above would be numerically
            // noisy right at this point. This only happens when b≈0 AND
            // lambdaMax≈a, which (since lambdaMax = max(a,d)) means a≥d — i.e.
            // already axis-aligned with the major axis along pixel-X.
            angle = 0
        }

        // Reject nonsense: sub-pixel, or bigger than the screen (degenerate /
        // near-collinear tags → huge circumcircle).
        guard semiMajorPx > 2, semiMajorPx < max(w, h) else { return nil }
        return CupPose(center: SIMD2<Float>(cPx.x / w, cPx.y / h),
                       axes: SIMD2<Float>(semiMajorPx / w, semiMinorPx / h),
                       angle: angle, confidence: 1)
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

    // Deliberately does nothing: `viewportSize` used to be set from
    // `uiView.bounds.size` here, but this struct's only property is a `let`
    // reference to `coordinator` — since that identity never changes, SwiftUI
    // has no reason to think this representable needs re-diffing after its
    // first appearance, so `updateUIView` was never guaranteed to run again
    // once the view's real (non-zero) laid-out size was actually available.
    // `viewportSize` is now driven by the top-level `GeometryReader` in
    // `CameraPourView.body` instead, which IS specifically designed to track
    // actual layout size reliably.
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
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
        // GeometryReader is the authoritative source for `viewportSize` — see
        // the comment on `ARCameraContainer.updateUIView` for why that path
        // couldn't be trusted to ever report the real laid-out size.
        GeometryReader { geo in
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
            .onAppear { coordinator.viewportSize = geo.size }
            .onChange(of: geo.size) { _, newSize in coordinator.viewportSize = newSize }
        }
        .ignoresSafeArea()
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
            Text("Pitcher: \(coordinator.pitcherTagCount)/\(1 + AprilTagRoles.pitcherReferenceIDs.count) tags")
            Text("Disc drawing: \(coordinator.discDrawing ? "yes" : "no")")
            Text(coordinator.debugLine)
                .foregroundStyle(.yellow)
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
