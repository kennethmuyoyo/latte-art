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
    /// A cut stroke, judged the way the reference fluid sim treats it — not
    /// at all: no preset path, no direction lock, no line. The user simply
    /// moves the pour; the sim's physics is what makes (or ruins) the
    /// pattern. The guide only OBSERVES that the stream genuinely traveled
    /// `travelUV` from where the stroke began (farthest distance ratchets;
    /// hover jitter is absorbed by a trailing anchor), then the step is
    /// done. The cue carries the technique ("cut through it toward
    /// yourself"); the physics rewards following it.
    case sweep(travelUV: Float)
}

/// One beat of a pour choreography: where the pour should land (whiteCircle
/// goals only — a sweep's path is the user's own), the goal that completes
/// the step (see `StepGoal`), and the full instruction text shown while it's
/// active. Data, not code — new patterns are just new arrays, no engine
/// changes.
struct PourStep {
    /// The pour spot for `.whiteCircle`; unused by `.sweep` (free direction).
    var targetUV: SIMD2<Float>
    var goal: StepGoal
    var cue: String
}

struct PourChoreography {
    var pattern: LattePattern
    var steps: [PourStep]
}
