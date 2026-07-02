import Foundation

/// Tracks how full the cup is (spec Focus B, fullness scalar). This is the app's
/// source of truth for the fill→foam transition; the height field in the solver
/// handles surface *look*, this handles fill *logic*.
final class LevelModel {
    /// Cup fullness, `0...1`. Rises as the user pours during the fill phase.
    private(set) var fillLevel: Float = 0

    /// Fraction at which the base is considered ready for foam.
    var fillThreshold: Float = 0.85
    /// Fraction beyond which we warn about overflowing.
    var overflowThreshold: Float = 0.98

    /// Larger = slower fill. Roughly "how many seconds of full-rate pour to fill".
    var secondsToFill: Float = 12

    var isFull: Bool { fillLevel >= fillThreshold }
    var isOverflowing: Bool { fillLevel >= overflowThreshold }

    /// Integrate one pour sample over `dt` seconds.
    func ingest(_ pour: PourSample, dt: Float) {
        let rate = pour.flowRate * pour.confidence
        fillLevel = min(1, fillLevel + rate * dt / secondsToFill)
    }

    /// No pour this frame: level simply holds (water doesn't drain).
    func idle(dt: Float) {}

    func reset() { fillLevel = 0 }
}
