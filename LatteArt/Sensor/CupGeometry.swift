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

        // In-plane basis anchored to the camera's own axes projected into the
        // cup plane (not to a tag edge). Today's pattern guidance (CupPose,
        // GuidanceOverlay) is implicitly camera-relative — CupPose.angle is
        // hardcoded 0 everywhere — so this keeps orientation consistent with
        // the rest of the stack without touching that code. A cup-anchored
        // orientation (pattern stays fixed relative to the cup as it rotates)
        // would be more physically correct but needs a real, tracked
        // CupPose.angle — a larger change, left as a future enhancement.
        var u = cameraRight - simd_dot(cameraRight, normal) * normal
        if simd_length(u) < 1e-5 { u = ab }  // degenerate fallback: camera looking edge-on
        u = simd_normalize(u)
        var v = simd_cross(normal, u)
        if simd_dot(v, cameraDown) < 0 { v = -v; u = -u }
        v = simd_normalize(v)

        return CupGeometry(center: center, radius: radius, normal: normal, basisU: u, basisV: v)
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
