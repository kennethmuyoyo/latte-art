import Foundation

/// Tracks how full the cup is. Feeds the fill readout and, via
/// `surfaceDepthBelowRimMeters`, the pour-height term in `PourPhysics`
/// (the surface rises toward the rim as the cup fills).
struct LevelModel {
    var cupTargetMl: Float = 220
    var cupDepthMeters: Float = 0.06
    private(set) var volumeMl: Float = 0

    mutating func add(volumeMl: Float) {
        self.volumeMl += volumeMl
    }

    /// `0...1`, clamped.
    var fillFraction: Float {
        min(max(volumeMl / cupTargetMl, 0), 1)
    }

    var isFull: Bool { fillFraction >= 1 }

    var isOverflowing: Bool { volumeMl > 1.05 * cupTargetMl }

    /// Depth of the liquid surface below the rim, meters — shrinks to 0 as the
    /// cup fills.
    var surfaceDepthBelowRimMeters: Float {
        cupDepthMeters * (1 - fillFraction)
    }

    mutating func reset() {
        volumeMl = 0
    }
}
