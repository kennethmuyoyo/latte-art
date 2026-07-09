import Foundation

/// Tracks how full the cup is. Feeds the fill readout and, via
/// `surfaceDepthBelowRimMeters`, the pour-height term in `PourPhysics`
/// (the surface rises toward the rim as the cup fills).
struct LevelModel {
    // Was 220 (a full drink, too slow to show any progress in a short rep),
    // then over-corrected to 90: combined with `PourPhysics.qMax` (65 ml/s),
    // a single decent pour could hit 100%/overflow in under 1.5s — well
    // inside just the FIRST step's hold duration. Since `surfaceDepthBelowRimMeters`
    // collapses to 0 as fillFraction hits 1, that made the height-dependent
    // physics (fall height, the float/sink transition) swing fast and
    // erratically partway through a normal attempt instead of changing
    // gradually across the whole pour — the "surface physics feels off"
    // symptom. 150 gives a more gradual curve across a full pattern while
    // still moving visibly within one rep.
    var cupTargetMl: Float = 150
    var cupDepthMeters: Float = 0.06

    /// The practice flow skips the blend/base phase entirely ("go straight
    /// into the art"), so every session starts with the cup already mostly
    /// full of blended base. This isn't just pacing: with an empty cup the
    /// surface sits `cupDepthMeters` below the rim, the resulting fall height
    /// drives the Froude number up, and φ collapses — white physically can't
    /// float, so a draw-first choreography could never form its pattern.
    var baseFillFraction: Float = 0.7

    private(set) var volumeMl: Float

    init() {
        volumeMl = baseFillFraction * cupTargetMl
    }

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
        volumeMl = baseFillFraction * cupTargetMl
    }
}
