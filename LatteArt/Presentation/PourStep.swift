import Foundation
import simd

/// What actually completes a step — a real, surface-derived goal, never a
/// timer. The old model held a fixed UV point for `duration` seconds of
/// wall-clock "on-track" time, which meant the coaching was judging the noisy
/// tracked spout position against a stopwatch while the simulated surface —
/// the thing the user is actually making — was ignored. Each case here is
/// judged in `PatternGuide.advance` against the pour AND the surface state
/// (`SurfaceState`) the sim reports every frame.
enum StepGoal {
    /// Pour steadily at `PourStep.targetUV`, close to the surface, until
    /// `milkMl` of FLOATED milk (∫ φ·flow·dt — the exact quantity the sim
    /// deposits as white dye) has been laid there. This is "until a white
    /// circle forms", measured by the circle actually forming, not by time
    /// spent hovering.
    case whiteCircle(milkMl: Float, maxHeightMeters: Float)
    /// A continuous pull from `targetUV` to `targetUVEnd` while pouring —
    /// the heart's finishing stroke through the circle, a tulip/rosetta
    /// pull-through. Completes when the pour has genuinely traversed the
    /// path (progress only ever ratchets forward, and only counts after the
    /// stroke started near the path's beginning); `lateralTolerance` is how
    /// far off the line still counts (wider for the rosetta's wiggle, which
    /// sways around the path on purpose).
    case sweep(lateralTolerance: Float)
}

/// One beat of a pour choreography: where the pour should land, the goal that
/// completes the step (see `StepGoal`), and the full instruction text shown
/// while it's active. Data, not code — new patterns are just new arrays, no
/// engine changes.
struct PourStep {
    var targetUV: SIMD2<Float>
    var goal: StepGoal
    var cue: String
    /// End of the path for `.sweep` goals; unused for `.whiteCircle`.
    var targetUVEnd: SIMD2<Float>? = nil
}

struct PourChoreography {
    var pattern: LattePattern
    var steps: [PourStep]
}
