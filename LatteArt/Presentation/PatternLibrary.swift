import simd

/// The 3 pattern choreographies, grounded in the real free-pour technique for
/// each — not arbitrary waypoints. Coaching `cue` text is verbatim from the
/// design spec's "During Practice" copy. Exact UV positions/timings are still
/// a reasonable first pass, NOT measured against real pour footage — expect
/// to retune these once testing on the physical rig (same category as the
/// tilt/occlusion constants elsewhere in Sensor/Simulation) — but the SHAPE
/// of each choreography (which steps are holds vs. sweeps) now matches how
/// each pattern is actually poured, which the previous "3 fixed dots for
/// every pattern" version didn't.
enum PatternLibrary {
    static func choreography(for pattern: LattePattern) -> PourChoreography {
        switch pattern {
        case .heart: return heart
        case .tulip: return tulip
        case .rosetta: return rosetta
        }
    }

    /// Real technique: pour into the CENTER to build a white base under the
    /// crema; once the cup is nearly full, hold steady at that same center
    /// point, close to the surface, letting the white circle grow; then, in
    /// ONE continuous motion, pull straight back toward the near rim,
    /// speeding up/lifting as you exit — that pull is what actually draws
    /// the heart's point, and it's a SWEEP, not a dot to aim at.
    private static let heart = PourChoreography(pattern: .heart, steps: [
        PourStep(targetUV: SIMD2(0.5, 0.5), direction: .zero, duration: 3.5,
                 cue: "Pour into the center to build a white base under the crema."),
        PourStep(targetUV: SIMD2(0.5, 0.5), direction: .zero, duration: 1.0,
                 cue: "Hold steady at the center, close to the surface — let the white circle grow."),
        PourStep(targetUV: SIMD2(0.5, 0.5), direction: SIMD2(0, 1), duration: 1.4,
                 cue: "In one motion, pull straight back toward the rim nearest you — speed up and lift as you exit.",
                 targetUVEnd: SIMD2(0.5, 0.88)),
    ])

    /// Real technique: a small held pour near the center, a brief pause
    /// (lift/break the stream) without moving off that spot, a second held
    /// pour stacked CLOSER to the rim (pushes the first circle out into a
    /// ring, the "stack" look), then the same single continuous pull-through
    /// to the near rim to finish/cap it.
    private static let tulip = PourChoreography(pattern: .tulip, steps: [
        PourStep(targetUV: SIMD2(0.5, 0.45), direction: .zero, duration: 1.4, cue: "Pour."),
        PourStep(targetUV: SIMD2(0.5, 0.45), direction: .zero, duration: 0.6, cue: "Pause."),
        PourStep(targetUV: SIMD2(0.5, 0.62), direction: .zero, duration: 1.2, cue: "Stack."),
        PourStep(targetUV: SIMD2(0.5, 0.62), direction: SIMD2(0, 1), duration: 1.2, cue: "Finish.",
                 targetUVEnd: SIMD2(0.5, 0.88)),
    ])

    /// Real technique: the wiggle ISN'T stationary — you sway the pitcher
    /// side to side WHILE steadily pulling it backward toward the near rim,
    /// laying down the fern's layered leaves as you go, then finish with a
    /// straight (non-wiggling) pull through the middle to define the stem.
    /// The first step's `wiggle` flag is display-only now (the guidance is
    /// text, no on-screen sway) — the `targetUVEnd` sweep is what still
    /// matters, since it drives on-track judgment.
    private static let rosetta = PourChoreography(pattern: .rosetta, steps: [
        PourStep(targetUV: SIMD2(0.5, 0.35), direction: SIMD2(0, 1), duration: 3.0, cue: "Start your wiggle.",
                 wiggle: true, targetUVEnd: SIMD2(0.5, 0.65)),
        PourStep(targetUV: SIMD2(0.5, 0.65), direction: .zero, duration: 0.8, cue: "Slow down."),
        PourStep(targetUV: SIMD2(0.5, 0.65), direction: SIMD2(0, 1), duration: 1.2, cue: "Pull through.",
                 targetUVEnd: SIMD2(0.5, 0.88)),
    ])
}
