import Foundation
import simd

/// One beat of a pour choreography: where the pour should land, which way it
/// should be moving (a hint for the arrow/coaching, not a hard requirement —
/// `direction` of `.zero` means "no particular direction, just hold position"),
/// how long this step lasts, and the coaching line shown while it's active.
/// Data, not code — new patterns are just new arrays, no engine changes.
struct PourStep {
    var targetUV: SIMD2<Float>
    var direction: SIMD2<Float>
    var duration: TimeInterval
    var note: String
}

struct PourChoreography {
    var pattern: LattePattern
    var steps: [PourStep]

    var totalDuration: TimeInterval { steps.reduce(0) { $0 + $1.duration } }
}
