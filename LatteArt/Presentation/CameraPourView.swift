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
import CoreVideo
import QuartzCore
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
    /// Which specific pitcher tag IDs are seen this frame (spout +
    /// whichever reference tags) — `pitcherTagCount` alone can't tell you
    /// WHICH tag dropped when tilt tracking goes bad.
    @Published private(set) var pitcherTagsDetected: Set<Int> = []
    @Published private(set) var trackerReady = false
    /// `false` only when the spout tag IS seen but sits outside the rim — the
    /// pour is suppressed (water would miss the cup). Distinct from "spout not
    /// detected" (that shows as a lower `pitcherTagCount`).
    @Published private(set) var spoutOverCup = true
    /// The detected cup as an on-screen ellipse for the SwiftUI guide ring —
    /// the true projected shape (see `cupPose(from:)`), not a forced circle.
    @Published private(set) var cupRing: CupRing? = nil
    /// Where the spout is right now, in cup UV — UNCLAMPED, i.e. this can sit
    /// outside the rim (radius > 0.5) when the spout really is off-cup. Computed
    /// directly from the tracked spout tag every frame the spout AND cup are
    /// both seen, independent of `PourSample`/on-track pour-gating — so the
    /// Practice guidance arrow (only shown while `spoutOverCup`) and the debug
    /// marker can both reflect the spout's true tracked position, not a
    /// clamped stand-in.
    @Published private(set) var spoutCupUV: SIMD2<Float>? = nil
    private var smoothedSpoutUV: SIMD2<Float>?
    /// `true` when this frame's spout position came from `PitcherRegistration`
    /// (the spout tag itself wasn't detected) rather than a genuine live
    /// detection — surfaced so the debug HUD can show the difference instead
    /// of `pitcherTagsDetected` silently looking the same either way.
    @Published private(set) var spoutReconstructed = false
    /// See where this is set in `ingest()` — an unthrottled, same-frame
    /// snapshot of the pour pipeline's own state, for comparing against
    /// `SimStats.hasSample` (published on a different, throttled cadence).
    @Published private(set) var pourDebugLine = "—"
    /// Captured the moment the spout AND a reference tag are seen together;
    /// lets the spout's position keep being tracked from just the reference
    /// tag afterward (see `PitcherRegistration`'s doc comment).
    private var pitcherRegistration: PitcherRegistration?
    /// DEBUG: distinguishes "3D circle math failed" (no cup transforms /
    /// degenerate triangle) from "2D screen projection failed" (cupPose(from:)
    /// returned nil despite a valid 3D circle) — same top-line `cupDetected`
    /// symptom, different cause. Also mirrors `blitter.drawsDisc` so the HUD
    /// can show it without reaching into a non-@Published class property.
    @Published private(set) var debugLine = "—"
    @Published private(set) var discDrawing = false

    struct CupRing: Equatable {
        var center: CGPoint
        var semiAxes: CGSize      // (semi-major, semi-minor), pixels — for display/rendering the OUTLINE only
        var angleRadians: Double  // y-down view space, matches CupPose.angle — same caveat
        /// Raw (smoothed) conjugate-diameter vectors, pixels — `center + dx·p
        /// + dy·q` is the EXACT map from a cup-UV offset (dx,dy) to a screen
        /// point. `semiAxes`/`angleRadians` are a lossy summary of the same
        /// ellipse (an eigendecomposition drops a rotation term that only
        /// matters for INTERIOR points, not for tracing the boundary curve) —
        /// fine for drawing the ring/disc outline, but mapping any specific
        /// point (the spout position, a pattern's target) through them
        /// instead of `p`/`q` directly is a real, systematic mapping error,
        /// not a jitter/precision issue — see `p`/`pPx` doc.
        var p: SIMD2<Float>
        var q: SIMD2<Float>
    }

    /// View size used to project cup geometry into normalized view space; set by
    /// the representable on layout.
    var viewportSize: CGSize = .zero

    /// The live camera view, held only for photo capture (`captureArtPhoto`) —
    /// set by `ARCameraContainer.makeUIView`, owned by SwiftUI.
    weak var arView: ARSCNView?

    /// Photograph the finished art as the user sees it: the live camera frame
    /// (real cup) with the painted sim surface composited on top. Main thread;
    /// completion is called on the main thread, `nil` only if the camera view
    /// isn't up. If the overlay readback fails the camera-only shot is still
    /// returned rather than nothing.
    func captureArtPhoto(_ completion: @escaping (UIImage?) -> Void) {
        guard let arView else { completion(nil); return }
        let camera = arView.snapshot()
        blitter.captureOverlay { overlay in
            guard let overlay else { completion(camera); return }
            // Both layers are full-screen and screen-aligned (see AppFlowView),
            // so drawing them into the same rect — regardless of each image's
            // native pixel scale — reproduces exactly what's on screen.
            let composed = UIGraphicsImageRenderer(size: camera.size).image { _ in
                let rect = CGRect(origin: .zero, size: camera.size)
                camera.draw(in: rect)
                overlay.draw(in: rect)
            }
            completion(composed)
        }
    }

    // Keep the disc + ring visible for a short beat after the cup was last
    // placed, so a one-frame tag dropout doesn't blink them off.
    private var lastCupSeenTime: TimeInterval = 0
    private var lastRing: CupRing?
    private let discHoldSeconds: TimeInterval = 0.3

    // Unlike the cup (physically static — held indefinitely once tracked,
    // see `smoothedWorldCenter`'s doc comment), the pitcher is EXPECTED to
    // move in and out of frame constantly, so `spoutCupUV` needs the
    // opposite behavior: a short grace period (just enough to survive a
    // single dropped frame), then actually clear, so the arrow/debug dot
    // disappear soon after the pitcher is genuinely removed instead of
    // showing a stale "ghost" position forever.
    private var lastSpoutSeenTime: TimeInterval = 0
    private let spoutHoldSeconds: TimeInterval = 0.2

    // Screen-space cup center + conjugate-diameter vectors feeding
    // `cupPose(from:)`, EMA-smoothed across frames to damp residual 2D
    // projection noise (see that method's doc comment). This stays LIVE —
    // never frozen — so the disc keeps following the real cup if the phone
    // or cup genuinely moves; the actual "jumps between points" bug lived
    // one layer down, in the 3D geometry (`smoothedWorldCenter` etc. below),
    // not here.
    private var smoothedCenter: SIMD2<Float>?
    private var smoothedP: SIMD2<Float>?
    private var smoothedQ: SIMD2<Float>?

    // World-space smoothing of the cup's rigid geometry itself. `ingest()`
    // computes `cup` two different ways depending on how many rim tags are
    // visible: an exact circumcenter from the raw 3-tag positions when all 3
    // are seen, or a rotation-based reconstruction (via `CupRegistration`)
    // from whichever 1-2 are seen otherwise. Tag visibility flickers
    // constantly during normal tracking (not just while pouring), so this
    // silently swaps between two methods with different noise/bias — the
    // reconstruction path in particular amplifies per-tag ROTATION noise
    // (rotation estimates from small planar tags are inherently less precise
    // than translation) by the cup's radius acting as a lever arm. That
    // amplified, method-dependent disagreement is what showed up as the ring
    // visibly relocating to a different point, repeatedly, regardless of
    // pouring. Smoothing the resulting `center`/`normal`/`radius` here, once,
    // damps that discontinuity for every downstream consumer (pour UV,
    // height-above-rim, occlusion, and the on-screen ellipse) instead of
    // patching each of them separately.
    private var smoothedWorldCenter: SIMD3<Float>?
    private var smoothedWorldNormal: SIMD3<Float>?
    private var smoothedWorldRadius: Float?

    /// Captured the moment all 3 cup tags are seen together; lets the cup
    /// keep tracking from just 1 or 2 of them afterward (see `CupRegistration`).
    /// Refreshed every frame all 3 ARE visible, so it self-corrects rather
    /// than locking in a single early (possibly noisy) snapshot.
    private var cupRegistration: CupRegistration?

    /// `true` while per-pixel LiDAR scene-depth occlusion is feeding the
    /// shader (see `updateSceneDepth`) — the tag-circle fallback holes are
    /// skipped then, and the HUD shows which occlusion path is live.
    @Published private(set) var sceneDepthActive = false
    /// Wraps ARKit's depth CVPixelBuffers as Metal textures with zero copies.
    private var depthTextureCache: CVMetalTextureCache?

    init?(context: MetalContext) {
        guard let sim = FluidSimulation(context: context),
              let blitter = FluidBlitter(context: context) else { return nil }
        let controller = SimulationController(sim: sim)
        blitter.controller = controller
        self.controller = controller
        self.blitter = blitter
        self.tracker = try? AprilTagTracker()
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, context.device, nil, &depthTextureCache)
        trackerReady = (tracker != nil)
        blitter.drawsDisc = false            // stay hidden until a cup is tracked
        controller.attach(source: source)    // same push path touch/demo use
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Per-pixel occlusion runs off EVERY ARKit frame (the depth map and
        // camera pose must stay in lockstep with the live image), not just
        // the frames the tag detector accepts — `tracker.process` drops
        // frames while a detection is in flight.
        updateSceneDepth(frame: frame)
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

    // MARK: - Per-pixel scene-depth occlusion (main thread)

    /// Feed the shader everything it needs to hide the surface at exactly
    /// the pixels where the real scene is in front of the cup plane — the
    /// pitcher's true measured silhouette, not a circle around a tag.
    /// Requires LiDAR (`sceneDepth` frame semantics, enabled in
    /// `ARCameraContainer`); on non-LiDAR devices `frame.sceneDepth` stays
    /// nil and the tag-circle fallback in `ingest()` takes over. Prefers
    /// `smoothedSceneDepth` — the raw map flickers at object edges.
    private func updateSceneDepth(frame: ARFrame) {
        guard let cache = depthTextureCache,
              let depthMap = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap,
              let planePoint = smoothedWorldCenter, let planeNormal = smoothedWorldNormal,
              viewportSize.width > 1 else {
            sceneDepthActive = false
            blitter.clearSceneDepth()
            return
        }
        var cvTextureOut: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, depthMap, nil, .r32Float,
            CVPixelBufferGetWidth(depthMap), CVPixelBufferGetHeight(depthMap), 0, &cvTextureOut)
        guard let cvTexture = cvTextureOut, let texture = CVMetalTextureGetTexture(cvTexture) else {
            sceneDepthActive = false
            blitter.clearSceneDepth()
            return
        }

        // Same orientation/viewport conventions as `cupPose(from:)` — the app
        // is locked to landscapeRight, and `viewportSize` is the same
        // points-based size the overlay is laid out with. The display
        // transform maps normalized image coords to normalized view coords;
        // the shader needs the opposite direction (its fragments live in
        // view space, the depth map in image space), hence `.inverted()`.
        let camera = frame.camera
        let viewMatrix = camera.viewMatrix(for: .landscapeRight)
        let projectionMatrix = camera.projectionMatrix(for: .landscapeRight,
                                                       viewportSize: viewportSize,
                                                       zNear: 0.01, zFar: 100)
        let m = camera.transform
        let cameraPos = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        // ARKit camera looks along -Z; depth values are meters along this axis.
        let cameraForward = -simd_normalize(SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let viewToImage = frame.displayTransform(for: .landscapeRight,
                                                 viewportSize: viewportSize).inverted()

        let uniform = DepthOcclusionUniform(
            inverseViewProjection: simd_inverse(projectionMatrix * viewMatrix),
            cameraPos: cameraPos,
            cameraForward: cameraForward,
            planePoint: planePoint,
            planeNormal: planeNormal,
            viewToImage: SIMD4<Float>(Float(viewToImage.a), Float(viewToImage.b),
                                      Float(viewToImage.c), Float(viewToImage.d)),
            viewToImageT: SIMD2<Float>(Float(viewToImage.tx), Float(viewToImage.ty)),
            drawableSize: .zero,   // the blitter fills this at draw time
            enabled: 1,
            // The scene must be at least this much nearer (meters) than the
            // cup plane before the surface hides — absorbs plane-tracking
            // noise so the rim/liquid never flicker, while a pouring pitcher
            // (several cm above the rim) cleanly occludes.
            margin: 0.01)
        blitter.setSceneDepth(texture: texture, holder: cvTexture, uniform: uniform)
        sceneDepthActive = true
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
        var holdingCup = false
        if cup == nil, let c = smoothedWorldCenter, let n = smoothedWorldNormal, let r = smoothedWorldRadius {
            // ZERO cup tags visible at all this frame — the pitcher has to
            // hover directly over the cup to pour into it, which is exactly
            // the position most likely to cover all 3 rim tags at once
            // (worst during a sweeping motion across the rim, e.g. tulip/
            // rosetta). Without this, `cup` goes nil, the pour source sees
            // no cup, and tracking drops outright the moment that happens —
            // which is what was being reported. The cup/camera are assumed
            // static for the session (same assumption the on-screen ring
            // relies on), so holding the last smoothed geometry here is a
            // trustworthy stand-in, not a guess.
            cup = CupGeometry.from(center: c, radius: r, normal: n, cameraRight: right, cameraDown: down)
            holdingCup = true
        }

        // Smooth the rigid geometry itself (see `smoothedWorldCenter`'s doc
        // comment) — damps the disagreement between the two computation
        // paths above before anything downstream (pour tracking, occlusion,
        // the on-screen ellipse) ever sees it. Deliberately never reset on a
        // loss: if `cup` is nil for a stretch, there's nothing new to blend
        // toward, so just hold the last smoothed estimate and resume
        // blending from it once tracking returns — no cold restart, no
        // discontinuity of its own.
        if let rawCup = cup {
            let worldSmoothing: Float = 0.2
            let center = smoothedWorldCenter.map { $0 + worldSmoothing * (rawCup.center - $0) } ?? rawCup.center
            let normal = smoothedWorldNormal.map {
                simd_normalize($0 + worldSmoothing * (rawCup.normal - $0))
            } ?? rawCup.normal
            let radius = smoothedWorldRadius.map { $0 + worldSmoothing * (rawCup.radius - $0) } ?? rawCup.radius
            smoothedWorldCenter = center
            smoothedWorldNormal = normal
            smoothedWorldRadius = radius
            cup = CupGeometry.from(center: center, radius: radius, normal: normal,
                                   cameraRight: right, cameraDown: down)
        }

        // Pitcher tags (spout + whichever tilt-reference tags are visible)
        // — full transforms preserved (not just position), so the source
        // can pick the best-conditioned reference, or fall back to a single
        // tag's own orientation for tilt if none are visible at all (see
        // AprilTagPourSource.tilt).
        var pitcher: [Int: simd_float4x4] = [:]
        if let s = world[AprilTagRoles.pitcherSpoutID] { pitcher[AprilTagRoles.pitcherSpoutID] = s }
        var pitcherReferenceTransforms: [Int: simd_float4x4] = [:]
        for refID in AprilTagRoles.pitcherReferenceIDs {
            if let t = world[refID] { pitcher[refID] = t; pitcherReferenceTransforms[refID] = t }
        }
        // Snapshot before any reconstruction below synthesizes an entry —
        // the debug HUD's per-tag readout should reflect what was actually
        // SEEN this frame, not what got filled in.
        pitcherTagsDetected = Set(pitcher.keys)

        // Spout tag dropping out mid-tilt is common (tilting the pitcher to
        // pour is exactly the motion that can rotate a spout-mounted tag
        // away from the camera) but the spout is otherwise required with no
        // fallback — losing it kills pour tracking at exactly the moment it
        // matters most. Mirror `CupRegistration`: cache the spout's rigid
        // offset from whichever reference tag(s) are visible the moment both
        // are seen together, then reconstruct the spout's position from that
        // cached offset whenever the spout itself isn't detected but a
        // reference tag still is.
        spoutReconstructed = false
        if let spoutTransform = pitcher[AprilTagRoles.pitcherSpoutID], !pitcherReferenceTransforms.isEmpty {
            pitcherRegistration = PitcherRegistration(spoutWorldPosition: position(spoutTransform),
                                                      referenceTransforms: pitcherReferenceTransforms)
        } else if pitcher[AprilTagRoles.pitcherSpoutID] == nil,
                  let reg = pitcherRegistration, !pitcherReferenceTransforms.isEmpty,
                  let reconstructed = reg.reconstructSpout(from: pitcherReferenceTransforms) {
            // Orientation is never consumed for a reconstructed spout (see
            // PitcherRegistration's doc comment) — a translation-only
            // transform is all downstream code needs.
            var synthesized = matrix_identity_float4x4
            synthesized.columns.3 = SIMD4<Float>(reconstructed.x, reconstructed.y, reconstructed.z, 1)
            pitcher[AprilTagRoles.pitcherSpoutID] = synthesized
            spoutReconstructed = true
        }

        // Live spout UV for the guidance arrow + debug marker — see
        // `spoutCupUV`'s doc comment. Tracks the spout continuously
        // regardless of whether a pour is actually active or suppressed
        // (off-cup) — deliberately NOT clamped to the rim here, so the debug
        // marker shows the true tracked position for verification. Light
        // smoothing only. Unlike the cup geometry, this DOES clear (after a
        // short grace period, see `spoutHoldSeconds`) when the spout is no
        // longer tracked — the pitcher is expected to leave the frame, so
        // holding a stale position here would show a ghost arrow/dot.
        if let cup, let spoutTransform = pitcher[AprilTagRoles.pitcherSpoutID] {
            let raw = cup.cupUV(of: position(spoutTransform))
            let smoothing: Float = 0.3
            let smoothed = smoothedSpoutUV.map { $0 + smoothing * (raw - $0) } ?? raw
            smoothedSpoutUV = smoothed
            spoutCupUV = smoothed
            lastSpoutSeenTime = time
        } else if time - lastSpoutSeenTime > spoutHoldSeconds {
            smoothedSpoutUV = nil
            spoutCupUV = nil
        }

        // Suppress the pour when the spout is over the table, not the cup mouth.
        // We already hold the real spout position AND the cup circle here (before
        // the source clamps anything), so we can just test whether the spout
        // projects inside the rim. If it's outside, drop the spout so the source
        // ends the pour (water misses the cup → no deposit) while the cup stays
        // tracked — the disc/ring keep showing, only the pouring stops.
        //
        // A real pour often lands right at/near the rim edge, not dead center —
        // exactly the zone a strict `isInside` (distance <= radius, no margin)
        // is most likely to reject on any real positional noise, and doubly so
        // for a `PitcherRegistration`-reconstructed spout (see that type's doc
        // comment on rotation-noise amplification over the reference→spout
        // offset). A ~20%-of-radius tolerance beyond the geometric rim absorbs
        // that noise without meaningfully changing what "off cup" means (still
        // rejects the spout being held out over the table).
        let offCupTolerance: Float = 0.2 * CupSpace.radius
        var offCup = false
        var pourPitcher = pitcher
        var rimDistanceForDebug: Float? = nil
        if let cup, let spoutTransform = pitcher[AprilTagRoles.pitcherSpoutID] {
            let d = CupSpace.signedDistanceToRim(cup.cupUV(of: position(spoutTransform)))
            rimDistanceForDebug = d
            if d > offCupTolerance {
                pourPitcher[AprilTagRoles.pitcherSpoutID] = nil
                offCup = true
            }
        }

        // Synchronized, UNTHROTTLED snapshot of exactly what's about to be
        // handed to `source.update(...)` this same frame — `SimStats`/
        // `hasSample` on the other hand is only published every 5th
        // `SimulationController.advance()` call, a different loop (the Metal
        // render loop, not this ARKit callback), so comparing the two after
        // the fact can show a stale mismatch. This line is always in lockstep
        // with `pitcherTagsDetected`/`spoutReconstructed` above.
        pourDebugLine = String(format: "cupNil=%@ spoutInPourPitcher=%@ offCup=%@ rimDist=%@",
                               cup == nil ? "Y" : "N",
                               pourPitcher[AprilTagRoles.pitcherSpoutID] == nil ? "N" : "Y",
                               offCup ? "Y" : "N",
                               rimDistanceForDebug.map { String(format: "%.3f", $0) } ?? "—")

        // Layering: the camera feed (real cup + pitcher) is the bottom layer
        // and the sim surface paints over it, so without this the surface
        // would always cover the pitcher. On LiDAR devices the clean per-pixel
        // path (`updateSceneDepth`) handles this with the pitcher's true
        // measured silhouette and these tag-circle holes are skipped; they
        // remain only as the non-LiDAR fallback — a hole where a pitcher tag
        // is depth-verified closer than the cup surface (see
        // `occluder(forTag:)`).
        //
        // `FluidBlitter`/the shader only have 2 occlusion slots — with up to
        // 3 pitcher tags (spout + 2 reference tags), cap defensively rather
        // than relying on FluidBlitter silently dropping the rest.
        var occluders: [Occluder] = []
        if !sceneDepthActive, let cup {
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

        // Read the source's OWN output back, same frame, unthrottled — isolates
        // whether `AprilTagPourSource` itself is producing a sample at all
        // (independent of `SimulationController`'s separately-clocked,
        // throttled `SimStats`/freshness gate). Also compares the ARKit frame
        // clock (`time`) against `CACurrentMediaTime()` — the freshness gate
        // assumes these are the same clock; if they've drifted apart (e.g.
        // real detection latency exceeding the 0.15s freshness window), that
        // gap shows up directly here.
        let clockGap = CACurrentMediaTime() - time
        if let s = source.current {
            pourDebugLine += String(format: " | source.current: tilt=%.1f° flow=%.2f clockGap=%.3fs",
                                    (s.tiltRadians ?? -1) * 180 / .pi, s.flowRate, clockGap)
        } else {
            pourDebugLine += String(format: " | source.current=NIL clockGap=%.3fs", clockGap)
        }

        // Seat the sim disc + guide ring on the real cup. Only count the cup as
        // placeable when the projection succeeds AND is sane — a near-collinear
        // tag layout (e.g. the 3 cup tags in a row on a flat test sheet) yields a
        // degenerate/huge circle, which we hide rather than paint over the feed.
        var ring: CupRing? = nil
        if cup == nil {
            debugLine = cupRegistration == nil
                ? "no 3D circle yet (need all 3 cup tags + non-collinear, once)"
                : "no cup tags visible at all (registered, but none in view)"
        } else if viewportSize.width <= 1 {
            debugLine = "viewport not laid out yet (\(viewportSize))"
        }
        if let cup, viewportSize.width > 1 {
            if let pose = cupPose(from: cup, camera: camera, viewport: viewportSize) {
                blitter.cupPose = pose
                // Hand the blitter the EXACT smoothed conjugate-diameter map
                // (normalized like `pose.center`), not just the (axes, angle)
                // eigen summary in `pose` — the summary is outline-only: it
                // drops a rotation term for interior points, and its `angle`
                // is noise-unstable near a circular projection, which made
                // the rendered disc content visibly rotate during a pour.
                // See `FluidBlitter.cupConjugates`.
                if let sp = smoothedP, let sq = smoothedQ {
                    let w = Float(viewportSize.width), h = Float(viewportSize.height)
                    blitter.cupConjugates = (SIMD2<Float>(sp.x / w, sp.y / h),
                                             SIMD2<Float>(sq.x / w, sq.y / h))
                }
                // `cupPose(from:)` just updated these as a side effect —
                // guaranteed non-nil here since it only returns non-nil after
                // successfully computing them.
                let r = CupRing(
                    center: CGPoint(x: CGFloat(pose.center.x) * viewportSize.width,
                                    y: CGFloat(pose.center.y) * viewportSize.height),
                    semiAxes: CGSize(width: CGFloat(pose.axes.x) * viewportSize.width,
                                     height: CGFloat(pose.axes.y) * viewportSize.height),
                    angleRadians: Double(pose.angle),
                    p: smoothedP ?? SIMD2<Float>(repeating: 0),
                    q: smoothedQ ?? SIMD2<Float>(repeating: 0))
                ring = r
                debugLine = String(format: "ring c(%.0f,%.0f) a(%.0f,%.0f)px θ%.0f°%@",
                                   r.center.x, r.center.y,
                                   r.semiAxes.width, r.semiAxes.height,
                                   r.angleRadians * 180 / .pi,
                                   holdingCup ? " [holding, 0 cup tags visible]" : "")
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
        pitcherTagCount = pitcherTagsDetected.count
        spoutOverCup = !offCup

        // TEMPORARY: surface why placement did/didn't happen.
        let vp = String(format: "vp %.0f×%.0f", viewportSize.width, viewportSize.height)
        let rad = cup.map { String(format: " R%.3fm", $0.radius) } ?? " R—"
        debugLine += " | " + vp + rad + (ring != nil ? " ok" : " noplace")
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
    ///
    /// Sizing intent: the hole should HUG the pitcher's silhouette. Too big
    /// and the cutout exposes raw camera feed AROUND the pitcher, which
    /// reads as the surface color being erased near the pitcher instead of
    /// the pitcher simply sitting on top of an intact surface. Since three
    /// tag holes (spout + 2 body refs) union together to cover the body,
    /// each individual hole can stay tight. Tune on device: raise if slivers
    /// of surface paint over the pitcher's edges, lower if surface visibly
    /// disappears around it.
    private static let pitcherBodyToTagRatio: Float = 2.0

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
    /// `p`/`q` (and the center) are EMA-smoothed across frames — damps
    /// residual 2D projection noise on top of the (now separately smoothed)
    /// 3D `cup` geometry this is fed. Deliberately stays LIVE, not frozen:
    /// the disc has to keep following the real cup if the phone or cup
    /// genuinely moves. The eigenvector-based angle fit is especially
    /// unstable near a circular ellipse (semi-major ≈ semi-minor, the common
    /// near-top-down view here) — smoothing the raw `p`/`q` vectors rather
    /// than the derived angle sidesteps the angle's own 180°-ambiguity
    /// wraparound, which a naive smoothed-angle average would get wrong.
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
        //
        // A near-overhead camera views the cup close to top-down, so the
        // projected shape sits close to a perfect circle essentially always
        // (not just as an occasional edge case) — semiMinorPx/semiMajorPx
        // stays close to 1. A circle's rotation isn't a meaningful quantity
        // at all (visually indistinguishable regardless of the value), and
        // right at that point the eigenvector direction is genuinely
        // undefined — tiny tag-position noise swings the computed angle
        // wildly frame to frame, which is what showed up as the ring
        // spinning and, since the arrow's target position is rotated by
        // this same angle, the arrow swinging around with it. Below the
        // eccentricity threshold, don't trust the measurement at all —
        // there's nothing real to measure — and just use 0.
        let eccentricity = semiMajorPx > 1e-4 ? semiMinorPx / semiMajorPx : 1
        let angle: Float
        if eccentricity > 0.92 {
            angle = 0
        } else if abs(b) > 1e-6 || abs(lambdaMax - a) > 1e-6 {
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
            let config = ARWorldTrackingConfiguration()
            // Real per-pixel scene depth (LiDAR) drives the clean surface-
            // under-pitcher occlusion — see CameraPourCoordinator.updateSceneDepth.
            // Prefer the temporally smoothed variant (raw depth flickers at
            // object edges); on non-LiDAR devices neither is supported and
            // the tag-circle occlusion fallback takes over automatically.
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                config.frameSemantics.insert(.smoothedSceneDepth)
            } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                config.frameSemantics.insert(.sceneDepth)
            }
            v.session.run(config)
        }
        coordinator.arView = v               // for photo capture — see captureArtPhoto
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
            Text("Occlusion: \(coordinator.sceneDepthActive ? "LiDAR per-pixel" : "tag circles (no LiDAR)")")
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
