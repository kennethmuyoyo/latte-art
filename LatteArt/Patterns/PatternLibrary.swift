import Foundation
import simd

/// The choreographies for each pattern, distilled from the reference clips.
///
/// Coordinates are cup-normalized UV: center is (0.5, 0.5), the near rim (cup
/// handle / user side) is toward y = 0.9, the far rim is y = 0.1.
///
/// NOTE: these are first-pass motions to build and tune against. Replace the
/// numbers with real barista timings when available — the engine doesn't change.
enum PatternLibrary {
    static func choreography(for pattern: LattePattern) -> PourChoreography {
        switch pattern {
        case .heart:   return heart
        case .tulip:   return tulip
        case .rosetta: return rosetta
        }
    }

    // Heart: pour high in the center to sink milk, drop low to build a round
    // white disc, then pull straight through it toward the near rim to cut the tip.
    private static var heart: PourChoreography {
        PourChoreography(pattern: .heart, steps: [
            PourStep(targetUV: [0.5, 0.5], duration: 3.0,
                     note: "Pour from high in the center to build the base."),
            PourStep(targetUV: [0.5, 0.42], duration: 3.0,
                     note: "Drop the jug low and let a white disc grow."),
            PourStep(targetUV: [0.5, 0.80], direction: [0, 1], duration: 1.5,
                     note: "Pull straight through the disc to the near rim."),
        ])
    }

    // Tulip: stacked pushes — build a blob, then push a second and third into it
    // from farther back, each shove nudging the previous forward.
    private static var tulip: PourChoreography {
        PourChoreography(pattern: .tulip, steps: [
            PourStep(targetUV: [0.5, 0.62], duration: 2.5,
                     note: "Build the first blob near the front."),
            PourStep(targetUV: [0.5, 0.50], direction: [0, 1], duration: 2.0,
                     note: "Push a second blob into the first."),
            PourStep(targetUV: [0.5, 0.40], direction: [0, 1], duration: 2.0,
                     note: "Push a third, stacking the leaves."),
            PourStep(targetUV: [0.5, 0.78], direction: [0, 1], duration: 1.5,
                     note: "Pull through to draw the stem."),
        ])
    }

    // Rosetta: start far, wiggle side to side to lay leaves while slowly dragging
    // back toward the near rim, then pull straight through to finish the stem.
    private static var rosetta: PourChoreography {
        PourChoreography(pattern: .rosetta, steps: [
            PourStep(targetUV: [0.5, 0.30], duration: 2.0,
                     note: "Pour high near the far side to sink the base."),
            PourStep(targetUV: [0.5, 0.40], direction: [0, 1], duration: 4.0, wiggle: 0.14,
                     note: "Wiggle side to side, dragging slowly toward you."),
            PourStep(targetUV: [0.5, 0.80], direction: [0, 1], duration: 1.5,
                     note: "Stop wiggling and pull straight through the stem."),
        ])
    }
}
