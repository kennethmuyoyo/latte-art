import Foundation
import simd

/// One beat of a pour choreography: where the pour should land, which way it
/// should be moving (a hint for coaching, not a hard requirement — `direction`
/// of `.zero` means "no particular direction, just hold position"), how long
/// this step lasts, and the full instruction text shown while it's active.
/// Data, not code — new patterns are just new arrays, no engine changes.
struct PourStep {
    var targetUV: SIMD2<Float>
    var direction: SIMD2<Float>
    var duration: TimeInterval
    var cue: String
    /// A back-and-forth "wiggle" step (rosetta) — display-only bookkeeping
    /// now (no on-screen sway is drawn); kept for the pattern data to stay
    /// descriptive and in case a future visual treatment wants it.
    var wiggle: Bool = false
    /// When set, this step's target isn't a fixed point to hold — it SWEEPS
    /// linearly from `targetUV` to `targetUVEnd` over `duration`. Real pour
    /// motions aren't all holds: a heart/tulip/rosetta's finishing "pull
    /// through" is a single continuous sweep toward the rim, not a point to
    /// sit on, and the on-track judgment (`PatternGuide.currentTargetUV`)
    /// needs to track wherever along that sweep you're currently supposed to
    /// be, not just the start.
    var targetUVEnd: SIMD2<Float>? = nil
}

struct PourChoreography {
    var pattern: LattePattern
    var steps: [PourStep]

    var totalDuration: TimeInterval { steps.reduce(0) { $0 + $1.duration } }
}
