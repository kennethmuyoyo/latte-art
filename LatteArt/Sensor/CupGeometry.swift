import simd

/// The cup's real-world circle, derived each frame from its 3 rim AprilTags.
/// Pure geometry — no ARKit/SceneKit types — so it's easy to reason about and
/// test independently of the AR session.
struct CupGeometry {
    /// World-space center of the rim circle.
    var center: SIMD3<Float>
    /// World-space circumradius of the rim circle, meters.
    var radius: Float
    /// Unit plane normal, sign-corrected to point toward world +Y (up).
    var normal: SIMD3<Float>
    /// Unit in-plane basis (camera-right projected into the plane).
    var basisU: SIMD3<Float>
    /// Unit in-plane basis, orthogonal to `basisU`, ~camera-down.
    var basisV: SIMD3<Float>

    /// Build the cup's circumcircle from its 3 rim tags (fixed order — always
    /// `AprilTagRoles.cupTagIDs[0/1/2]`, never sorted by detection order, so
    /// `basisU`'s degenerate fallback below doesn't flip frame to frame).
    ///
    /// Circumcenter via the standard vector formula (Ericson, Real-Time
    /// Collision Detection): for triangle A,B,C with ab = B-A, ac = C-A,
    ///   toCenter = (|ac|² (ab×ac × ab) + |ab|² (ac × ab×ac)) / (2 |ab×ac|²)
    /// `normal` is `ab × ac`, sign-flipped toward world +Y.
    ///
    /// Returns `nil` if the 3 points are (near-)collinear — happens
    /// transiently on partial/noisy detections.
    static func fromCupTags(a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>,
                             cameraRight: SIMD3<Float>, cameraDown: SIMD3<Float>) -> CupGeometry? {
        let ab = b - a, ac = c - a
        let abXac = simd_cross(ab, ac)
        let cross2 = simd_length_squared(abXac)
        guard cross2 > 1e-10 else { return nil }

        let toCenter = (simd_length_squared(ac) * simd_cross(abXac, ab)
                       + simd_length_squared(ab) * simd_cross(ac, abXac)) / (2 * cross2)
        let center = a + toCenter
        let radius = simd_length(toCenter)

        var normal = simd_normalize(abXac)
        if simd_dot(normal, SIMD3<Float>(0, 1, 0)) < 0 { normal = -normal }

        let (u, v) = cameraRelativeBasis(normal: normal, cameraRight: cameraRight,
                                         cameraDown: cameraDown, fallback: ab)
        return CupGeometry(center: center, radius: radius, normal: normal, basisU: u, basisV: v)
    }

    /// Builds a `CupGeometry` from an already-known (center, radius, normal)
    /// — the camera-INDEPENDENT part of the geometry, as reconstructed by
    /// `CupRegistration` when fewer than all 3 cup tags are visible. Computes
    /// `basisU`/`basisV` with the exact same camera-relative formula
    /// `fromCupTags` uses, so a reconstructed frame's on-screen behavior is
    /// identical to a fully-observed one.
    static func from(center: SIMD3<Float>, radius: Float, normal: SIMD3<Float>,
                     cameraRight: SIMD3<Float>, cameraDown: SIMD3<Float>) -> CupGeometry {
        // No tag-edge fallback direction available here (unlike fromCupTags,
        // which has `ab`) — camera-edge-on degenerate views are rare enough,
        // and brief, that falling back to a fixed world axis is acceptable.
        let (u, v) = cameraRelativeBasis(normal: normal, cameraRight: cameraRight,
                                         cameraDown: cameraDown, fallback: SIMD3<Float>(1, 0, 0))
        return CupGeometry(center: center, radius: radius, normal: normal, basisU: u, basisV: v)
    }

    /// In-plane basis anchored to the camera's own axes projected into the
    /// cup plane (not to a tag edge). Today's pattern guidance (CupPose,
    /// GuidanceOverlay) is implicitly camera-relative — CupPose.angle is
    /// hardcoded 0 everywhere — so this keeps orientation consistent with the
    /// rest of the stack without touching that code. A cup-anchored
    /// orientation (pattern stays fixed relative to the cup as it rotates)
    /// would be more physically correct but needs a real, tracked
    /// CupPose.angle — a larger change, left as a future enhancement.
    private static func cameraRelativeBasis(normal: SIMD3<Float>, cameraRight: SIMD3<Float>,
                                            cameraDown: SIMD3<Float>, fallback: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        var u = cameraRight - simd_dot(cameraRight, normal) * normal
        if simd_length(u) < 1e-5 { u = fallback }  // degenerate fallback: camera looking edge-on
        u = simd_normalize(u)
        var v = simd_cross(normal, u)
        if simd_dot(v, cameraDown) < 0 { v = -v; u = -u }
        v = simd_normalize(v)
        return (u, v)
    }

    /// Project a world point onto this cup's local UV frame (matches
    /// `CupSpace`: center (0.5,0.5), radius 0.5). Not clamped — caller clamps.
    func cupUV(of worldPoint: SIMD3<Float>) -> SIMD2<Float> {
        let rel = worldPoint - center
        let local = SIMD2<Float>(simd_dot(rel, basisU), simd_dot(rel, basisV)) / max(radius, 1e-5)
        return CupSpace.center + local * CupSpace.radius
    }

    /// Signed height of a world point above this cup's plane, meters, +up.
    func heightAbovePlane(_ worldPoint: SIMD3<Float>) -> Float {
        simd_dot(worldPoint - center, normal)
    }
}

/// Caches the cup's CENTER and PLANE NORMAL's fixed relationship to each cup
/// tag's own local pose, captured the moment all 3 tags are seen together (a
/// "registration"). Once cached, that camera-INDEPENDENT part of the cup's
/// geometry can be reconstructed from ANY ONE of the 3 tags' live pose alone
/// — letting tracking survive 1 or even 2 of the 3 tags being occluded,
/// instead of needing all 3 visible every single frame.
///
/// `basisU`/`basisV` are deliberately NOT cached here: per `CupGeometry`'s own
/// doc comment, those are intentionally recomputed from the CURRENT camera
/// direction every frame (so on-screen orientation tracks the viewer, not the
/// physical tags) — a caller reconstructing geometry from this registration
/// still needs to rebuild them the same way `fromCupTags` does, from the
/// reconstructed normal + the current camera direction.
///
/// Radius and normal ARE rigid, camera-independent quantities (pure functions
/// of the 3 tags' world POSITIONS — normal's sign-fix against world +Y is a
/// gravity reference, not a camera one), so caching them per-tag and
/// re-deriving them from a single tag's live pose is valid regardless of
/// where the camera has moved to since registration.
struct CupRegistration {
    private struct Anchor {
        var centerLocal: SIMD3<Float>   // cup center, expressed in this tag's own local frame
        var normalLocal: SIMD3<Float>   // cup plane normal, expressed in this tag's own local frame (direction, not a point)
    }

    private let radius: Float
    private let anchors: [Int: Anchor]

    /// Captures a fresh registration from this frame's full 3-tag geometry.
    /// Call this every frame all 3 tags ARE visible — cheap, and
    /// self-correcting against any small mounting/measurement drift, rather
    /// than maintaining one long-lived running average.
    init(cup: CupGeometry, tagWorldTransforms: [Int: simd_float4x4]) {
        radius = cup.radius
        let centerH = SIMD4<Float>(cup.center.x, cup.center.y, cup.center.z, 1)
        let normalH = SIMD4<Float>(cup.normal.x, cup.normal.y, cup.normal.z, 0)
        anchors = tagWorldTransforms.mapValues { tagWorld in
            let inv = tagWorld.inverse
            let cl = inv * centerH
            let nl = inv * normalH
            return Anchor(centerLocal: SIMD3<Float>(cl.x, cl.y, cl.z),
                         normalLocal: SIMD3<Float>(nl.x, nl.y, nl.z))
        }
    }

    /// Reconstructs (center, radius, normal) — the rigid, camera-independent
    /// part of `CupGeometry` — from whichever registered tags are visible
    /// THIS frame, averaging across however many are available for a more
    /// stable result than picking one arbitrarily. `nil` if none of the
    /// tags this registration knows about are visible this frame.
    func reconstruct(from liveTransforms: [Int: simd_float4x4]) -> (center: SIMD3<Float>, radius: Float, normal: SIMD3<Float>)? {
        var centerSum = SIMD3<Float>(repeating: 0)
        var normalSum = SIMD3<Float>(repeating: 0)
        var count: Float = 0
        for (id, anchor) in anchors {
            guard let live = liveTransforms[id] else { continue }
            let cl = SIMD4<Float>(anchor.centerLocal.x, anchor.centerLocal.y, anchor.centerLocal.z, 1)
            let nl = SIMD4<Float>(anchor.normalLocal.x, anchor.normalLocal.y, anchor.normalLocal.z, 0)
            let c = live * cl
            let n = live * nl
            centerSum += SIMD3<Float>(c.x, c.y, c.z)
            normalSum += SIMD3<Float>(n.x, n.y, n.z)
            count += 1
        }
        guard count > 0 else { return nil }
        return (center: centerSum / count, radius: radius, normal: simd_normalize(normalSum / count))
    }
}
