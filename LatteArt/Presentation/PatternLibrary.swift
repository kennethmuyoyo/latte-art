import simd

/// The 3 pattern choreographies, grounded in the real free-pour technique for
/// each. The blend/base ("mixing") phase is deliberately skipped — practice
/// goes straight into drawing the art on a pre-filled base (see
/// `LevelModel.baseFillFraction`). Steps complete on surface-derived goals
/// (white actually laid, a stroke actually traversed — see `StepGoal`), never
/// on timers. Exact UV positions/quantities are a reasonable first pass, NOT
/// measured against real pour footage — expect to retune on the physical rig.
enum PatternLibrary {
    static func choreography(for pattern: LattePattern) -> PourChoreography {
        switch pattern {
        case .heart: return heart
        case .tulip: return tulip
        case .rosetta: return rosetta
        }
    }

    /// How close to the surface "close to the surface" is, meters above the
    /// rim plane. Above this the milk plunges instead of floating (and the
    /// coaching says to lower the pitcher).
    private static let drawHeight: Float = 0.05

    /// Real technique (blend phase skipped): hold the pour in ONE spot at the
    /// center, close to the surface — the incoming milk parts the surface and
    /// spreads it into a circle that blooms toward the user (the stream's
    /// fixed jet — see `k_milkStream` in Fluid.metal) — then ONE cut through
    /// the whole circle. The cut is not judged as a line (the reference sim
    /// has no such concept — see `StepGoal.sweep`); the cue steers it toward
    /// the near rim because a cut moving WITH the jet is the one whose exit
    /// gets pulled into the heart's point — the physics itself rewards the
    /// right direction.
    private static let heart = PourChoreography(pattern: .heart, steps: [
        PourStep(targetUV: SIMD2(0.5, 0.5),
                 goal: .whiteCircle(milkMl: 30, maxHeightMeters: drawHeight),
                 cue: "Hold the pour at the center — let the circle form."),
        PourStep(targetUV: SIMD2(0.5, 0.5),
                 goal: .sweep(travelUV: 0.45),
                 cue: "Lift and cut through the circle, toward yourself."),
    ])

    /// Real technique: stack several short pours on top of one another, each
    /// pushing into the previous one, then pull through the center to connect
    /// the layers.
    private static let tulip = PourChoreography(pattern: .tulip, steps: [
        PourStep(targetUV: SIMD2(0.5, 0.42),
                 goal: .whiteCircle(milkMl: 18, maxHeightMeters: drawHeight),
                 cue: "Short pour, close to the surface — first petal."),
        PourStep(targetUV: SIMD2(0.5, 0.56),
                 goal: .whiteCircle(milkMl: 14, maxHeightMeters: drawHeight),
                 cue: "Another short pour, slightly closer to you."),
        PourStep(targetUV: SIMD2(0.5, 0.68),
                 goal: .whiteCircle(milkMl: 10, maxHeightMeters: drawHeight),
                 cue: "One more, pushing into the last."),
        PourStep(targetUV: SIMD2(0.5, 0.68),
                 goal: .sweep(travelUV: 0.35),
                 cue: "Pull straight through the stack."),
    ])

    /// Real technique: wiggle side to side while steadily moving backward to
    /// lay the leaf layers (the wiggle sways AROUND the travel line, hence
    /// the wide lateral tolerance), then stop the wiggle and pull straight
    /// through the middle to form the stem.
    private static let rosetta = PourChoreography(pattern: .rosetta, steps: [
        PourStep(targetUV: SIMD2(0.5, 0.5),
                 goal: .sweep(travelUV: 0.35),
                 cue: "Wiggle side to side while moving back slowly."),
        PourStep(targetUV: SIMD2(0.5, 0.5),
                 goal: .sweep(travelUV: 0.5),
                 cue: "Stop the wiggle — pull through the middle."),
    ])
}
