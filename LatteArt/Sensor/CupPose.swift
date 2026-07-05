import CoreGraphics
import simd

/// Where the cup sits on screen: an ellipse (perspective view of a circle).
/// On device it's the projection of the ARKit dot-tracked cup; in the Simulator
/// it's a centered virtual cup. Consumed by the compositor/overlays to warp the
/// sim's normalized circle onto the real rim.
///
/// All values are in normalized view coordinates `[0,1]` (y-down), so they are
/// resolution-independent.
struct CupPose: Equatable {
    /// Ellipse center in normalized view space.
    var center: SIMD2<Float>
    /// Semi-axis lengths (half-width, half-height) in normalized view space.
    var axes: SIMD2<Float>
    /// Rotation of the ellipse major axis, radians.
    var angle: Float
    /// Detection confidence `0...1`.
    var confidence: Float

    /// A centered, unrotated default so the app is usable before/without detection
    /// (e.g. in the Simulator with a virtual cup).
    static let centeredDefault = CupPose(
        center: SIMD2<Float>(0.5, 0.5),
        axes: SIMD2<Float>(0.42, 0.42),
        angle: 0,
        confidence: 0
    )

    /// Map a point from cup-normalized `CupSpace` UV into normalized view space.
    func viewPoint(fromCupUV uv: SIMD2<Float>) -> SIMD2<Float> {
        // Cup UV -> centered unit disk coords in [-1, 1].
        let d = (uv - CupSpace.center) / CupSpace.radius
        let c = cos(angle), s = sin(angle)
        // Scale by axes, then rotate, then translate to view center.
        let scaled = SIMD2<Float>(d.x * axes.x, d.y * axes.y)
        let rotated = SIMD2<Float>(scaled.x * c - scaled.y * s,
                                   scaled.x * s + scaled.y * c)
        return center + rotated
    }

    /// Near-equality within a tolerance. Used by continuous tracking to skip
    /// publishing sub-pixel per-frame jitter (which would churn SwiftUI at 60Hz).
    func approxEquals(_ other: CupPose, tol: Float = 0.002) -> Bool {
        abs(center.x - other.center.x) < tol && abs(center.y - other.center.y) < tol &&
        abs(axes.x - other.axes.x) < tol && abs(axes.y - other.axes.y) < tol &&
        abs(angle - other.angle) < tol && confidence == other.confidence
    }

    /// Inverse of `viewPoint`: normalized view space -> cup-normalized UV.
    func cupUV(fromViewPoint p: SIMD2<Float>) -> SIMD2<Float> {
        let t = p - center
        let c = cos(-angle), s = sin(-angle)
        let unrot = SIMD2<Float>(t.x * c - t.y * s, t.x * s + t.y * c)
        let d = SIMD2<Float>(unrot.x / max(axes.x, 1e-5),
                             unrot.y / max(axes.y, 1e-5))
        return CupSpace.center + d * CupSpace.radius
    }
}
