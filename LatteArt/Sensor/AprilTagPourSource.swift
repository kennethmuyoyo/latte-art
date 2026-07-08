import Foundation
import simd
import QuartzCore

/// Pour source driven by the pitcher's AprilTags: the spout tag (required —
/// fixes the pour's landing point) plus whichever of `AprilTagRoles.
/// pitcherReferenceIDs` is currently visible (used for tilt). Replaces
/// touch-drag on the ARKit device path entirely: as the real pitcher moves and
/// tilts over the real cup, this produces the same `PourSample` stream
/// `TouchPourSource` produces for the Simulator, so the rest of the app is
/// unaffected.
///
/// Populates `PourSample.tiltRadians` / `.heightAboveRimMeters` with the raw
/// measurements — see the contract note on `PourSample`. `flowRate` /
/// `layingMilk` are also filled in as a derived legacy convenience, but
/// Simulation's `PourPhysics` should treat the raw fields as the source of
/// truth and own the tilt→flow curve and mixing/drawing decision itself.
final class AprilTagPourSource: PourSource {
    private(set) var current: PourSample?
    var onSample: ((PourSample) -> Void)?

    /// Height above the cup's rim plane (meters) below which the pour is
    /// considered "drawing" (foam, layingMilk=true) rather than "mixing"
    /// (plunging from height, layingMilk=false). Legacy-field derivation only
    /// — Simulation should derive this decision itself from the raw
    /// `heightAboveRimMeters` (e.g. via the Froude gate), not read this bool.
    var layingMilkHeightThresholdMeters: Float = 0.045
    /// Tilt angle (radians, from horizontal) mapped to legacy `flowRate`
    /// 0...1. Simulation should prefer computing flow from raw
    /// `tiltRadians` via its own flow curve instead of reading `flowRate`.
    var restAngle: Float = 0.15
    var maxAngle: Float = 1.1
    /// Grace period before a momentary tag occlusion (e.g. a hand passing in
    /// front for one frame) ends the pour outright — mirrors the ~100ms
    /// freshness gate `SimulationController.advance()` already applies to any
    /// `PourSource`, so a pour doesn't visibly stutter on a single bad frame.
    private let graceSeconds: TimeInterval = 0.15

    private var lastGoodSampleTime: TimeInterval = 0
    private var active = false

    func start() { active = true }
    func stop() { active = false; current = nil }

    /// Called every ARFrame with this frame's pitcher tag world TRANSFORMS
    /// (position + orientation; may be missing any of them) and the current
    /// cup geometry (nil until the cup is acquired). Position is required from
    /// the spout tag specifically — it's what fixes the pour's landing point —
    /// but tilt can come from whichever reference tag is visible (preferring
    /// the one farthest from the spout) or, if none are, the spout tag's own
    /// orientation alone; see `tilt(...)`.
    func update(pitcherWorldTransforms: [Int: simd_float4x4], cup: CupGeometry?, time: TimeInterval) {
        guard active, let cup else { end(at: time); return }
        guard let spoutTransform = pitcherWorldTransforms[AprilTagRoles.pitcherSpoutID] else {
            end(at: time); return
        }
        let spout = SIMD3<Float>(spoutTransform.columns.3.x, spoutTransform.columns.3.y, spoutTransform.columns.3.z)

        // Prefer whichever visible reference tag sits farthest from the
        // spout — on a roughly-cylindrical pitcher, farthest-from-spout is
        // closest to directly opposite it, which gives the tipping motion
        // its strongest, least noise-sensitive vertical excursion (see
        // tilt(...) doc comment).
        let referenceTransform = AprilTagRoles.pitcherReferenceIDs
            .compactMap { pitcherWorldTransforms[$0] }
            .max { a, b in
                let da = simd_distance(SIMD3<Float>(a.columns.3.x, a.columns.3.y, a.columns.3.z), spout)
                let db = simd_distance(SIMD3<Float>(b.columns.3.x, b.columns.3.y, b.columns.3.z), spout)
                return da < db
            }
        let tilt = Self.tilt(spout: spout, spoutTransform: spoutTransform, referenceTransform: referenceTransform)

        let uv = CupSpace.clampToCup(cup.cupUV(of: spout))
        // Real 3D translation is already available from tag pose estimation,
        // so pour height is this direct plane-relative distance rather than
        // the pixel-size-vs-camera proxy a depth-less system would need.
        let height = cup.heightAbovePlane(spout)
        let laying = height <= layingMilkHeightThresholdMeters

        let flow = min(1, max(0, (tilt - restAngle) / max(maxAngle - restAngle, 1e-4)))

        var velocity = SIMD2<Float>(0, 0)
        if let prev = current {
            let dt = Float(max(time - prev.time, 1.0 / 120.0))
            velocity = (uv - prev.uv) / dt
        }

        var sample = PourSample(uv: uv, velocity: velocity, flowRate: flow, confidence: 1, time: time)
        sample.layingMilk = laying
        sample.tiltRadians = tilt
        sample.heightAboveRimMeters = height
        current = sample
        lastGoodSampleTime = time
        onSample?(sample)
    }

    /// Pitcher tilt, radians from horizontal — preferring the two-tag
    /// baseline (spout + whichever reference tag is visible, chosen by the
    /// caller to be the one farthest from the spout), falling back to the
    /// spout tag's own orientation when no reference tag is visible at all.
    ///
    /// Two-tag method: the angle of the spout→reference vector from
    /// horizontal. For a rigid pitcher the raw 3D distance between the two
    /// tags stays ~fixed regardless of tilt, but this angle changes exactly
    /// as the pitcher tips over to pour — PROVIDED the reference tag is
    /// roughly aligned with the pour direction (i.e. close to directly
    /// opposite the spout). A reference tag mounted 90° around instead of
    /// opposite gives a weaker, noisier reading: as the pitcher tips about
    /// an axis roughly perpendicular to the pour direction, points aligned
    /// WITH that direction (front/back) sweep the most vertically for a
    /// given tilt, while points off to the side (90°) sweep much less —
    /// smaller signal, and the same absolute position noise produces a
    /// larger angular error over a shorter horizontal baseline. This is why
    /// the caller prefers whichever visible reference tag is farthest from
    /// the spout, and why `docs/tags/PLACEMENT.md` recommends mounting an
    /// additional reference tag directly opposite the spout rather than
    /// merely "somewhere else on the body".
    ///
    /// Single-tag fallback: `estimatePose` returns the tag's full orientation,
    /// not just its position — `spoutTransform.columns.1` is the world-space
    /// image of the tag's own local +Y axis (its printed "up" direction).
    /// PROVIDED the tag is mounted upright (its printed up-arrow aligned with
    /// the pitcher's true vertical when at rest — see docs/tags/PLACEMENT.md),
    /// that axis points straight up at rest and tips away from world +Y by
    /// exactly the pitcher's tilt as it pours. ARKit's world is gravity-aligned
    /// by default, so world +Y ≡ "up" is a safe reference. Noisier than the
    /// two-tag baseline (small-tag rotation estimates are less precise than
    /// translation), but keeps the pour alive through a total reference-tag
    /// dropout instead of stopping it outright.
    private static func tilt(spout: SIMD3<Float>, spoutTransform: simd_float4x4,
                             referenceTransform: simd_float4x4?) -> Float {
        if let referenceTransform {
            let reference = SIMD3<Float>(referenceTransform.columns.3.x, referenceTransform.columns.3.y, referenceTransform.columns.3.z)
            let d = spout - reference
            let horiz = simd_length(SIMD2<Float>(d.x, d.z))
            return atan2(abs(d.y), max(horiz, 1e-4))
        }
        let up = simd_normalize(SIMD3<Float>(spoutTransform.columns.1.x,
                                             spoutTransform.columns.1.y,
                                             spoutTransform.columns.1.z))
        let cosAngle = simd_dot(up, SIMD3<Float>(0, 1, 0))
        return acos(min(max(cosAngle, -1), 1))
    }

    private func end(at time: TimeInterval) {
        guard time - lastGoodSampleTime > graceSeconds else { return }
        current = nil
    }
}
