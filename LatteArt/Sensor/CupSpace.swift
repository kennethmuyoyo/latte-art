import CoreGraphics
import simd

/// Cup-normalized coordinate space shared by every module.
///
/// The whole app speaks ONE coordinate space so perception, simulation, and
/// guidance never have to agree on pixels. Only the compositor knows pixels.
///
/// - Origin `(0.5, 0.5)` is the cup center.
/// - The cup rim is the unit circle: a point is inside the cup when
///   `distance(uv, 0.5) <= 0.5`.
/// - `uv` axes run `[0,1]`, y-down (matches texture/UV convention).
///
/// The physical cup on screen is an ellipse (perspective); `CupPose` carries the
/// view-space mapping. Modules work in this clean circle; the compositor warps.
enum CupSpace {
    static let center = SIMD2<Float>(0.5, 0.5)
    static let radius: Float = 0.5

    static func isInside(_ uv: SIMD2<Float>) -> Bool {
        simd_distance(uv, center) <= radius
    }

    /// Signed distance to the rim in UV units (negative inside, 0 at rim).
    static func signedDistanceToRim(_ uv: SIMD2<Float>) -> Float {
        simd_distance(uv, center) - radius
    }

    /// Clamp a UV point to lie within the cup circle.
    static func clampToCup(_ uv: SIMD2<Float>) -> SIMD2<Float> {
        let d = uv - center
        let len = simd_length(d)
        guard len > radius else { return uv }
        return center + d / len * radius
    }
}
