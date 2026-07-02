import Foundation
import simd

/// One instruction in a pour choreography (spec §8). Patterns are DATA, not
/// code: tulip/heart/rosetta are just different `[PourStep]` arrays, so new
/// patterns are added without touching the solver.
struct PourStep: Identifiable {
    let id = UUID()

    /// Where to pour, in cup-normalized UV.
    var targetUV: SIMD2<Float>
    /// Intended pour drag direction (unit-ish vector); `.zero` means "hold still".
    var direction: SIMD2<Float>
    /// How long this step should last, seconds.
    var duration: Float
    /// Lateral wiggle amplitude in UV (rosetta's back-and-forth); 0 = none.
    var wiggle: Float
    /// Coaching text shown while this step is active.
    var note: String

    init(targetUV: SIMD2<Float>,
         direction: SIMD2<Float> = .zero,
         duration: Float,
         wiggle: Float = 0,
         note: String) {
        self.targetUV = targetUV
        self.direction = simd_length(direction) > 0 ? simd_normalize(direction) : .zero
        self.duration = duration
        self.wiggle = wiggle
        self.note = note
    }
}

/// A named pour choreography with an ideal template for scoring.
struct PourChoreography {
    var pattern: LattePattern
    var steps: [PourStep]

    var totalDuration: Float { steps.reduce(0) { $0 + $1.duration } }
}
