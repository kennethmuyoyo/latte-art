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
    /// center, close to the surface — the stream's own forward carry drifts
    /// the growing circle ahead (see `SimulationController.streamCarry`) —
    /// then cut back straight THROUGH the whole circle toward the near rim.
    /// The cut starts on the far side of where the circle has drifted, so the
    /// stroke pierces it completely and folds the lobes into the heart.
    private static let heart = PourChoreography(pattern: .heart, steps: [
        PourStep(targetUV: SIMD2(0.5, 0.5),
                 goal: .whiteCircle(milkMl: 30, maxHeightMeters: drawHeight),
                 cue: "Pour steadily in one spot at the center, close to the surface, until a white circle forms."),
        PourStep(targetUV: SIMD2(0.5, 0.38),
                 goal: .sweep(lateralTolerance: 0.15),
                 cue: "Lift slightly and cut straight back through the circle, toward the rim nearest you.",
                 targetUVEnd: SIMD2(0.5, 0.88)),
    ])

    /// Real technique: stack several short pours on top of one another, each
    /// pushing into the previous one, then pull through the center to connect
    /// the layers.
    private static let tulip = PourChoreography(pattern: .tulip, steps: [
        PourStep(targetUV: SIMD2(0.5, 0.42),
                 goal: .whiteCircle(milkMl: 18, maxHeightMeters: drawHeight),
                 cue: "Close to the surface, make a short pour — the first petal."),
        PourStep(targetUV: SIMD2(0.5, 0.56),
                 goal: .whiteCircle(milkMl: 14, maxHeightMeters: drawHeight),
                 cue: "Short pour again, slightly closer to you — push into the first petal."),
        PourStep(targetUV: SIMD2(0.5, 0.68),
                 goal: .whiteCircle(milkMl: 10, maxHeightMeters: drawHeight),
                 cue: "One more small pour, pushing into the last one."),
        PourStep(targetUV: SIMD2(0.5, 0.68),
                 goal: .sweep(lateralTolerance: 0.15),
                 cue: "Pull the pitcher through the center to connect the layers into a tulip.",
                 targetUVEnd: SIMD2(0.5, 0.88)),
    ])

    /// Real technique: wiggle side to side while steadily moving backward to
    /// lay the leaf layers (the wiggle sways AROUND the backward path, hence
    /// the wide lateral tolerance), then stop the wiggle and pull straight
    /// through the middle to form the stem.
    private static let rosetta = PourChoreography(pattern: .rosetta, steps: [
        PourStep(targetUV: SIMD2(0.5, 0.35),
                 goal: .sweep(lateralTolerance: 0.25),
                 cue: "Close to the surface, gently wiggle left and right while slowly moving backward.",
                 targetUVEnd: SIMD2(0.5, 0.7)),
        PourStep(targetUV: SIMD2(0.5, 0.7),
                 goal: .sweep(lateralTolerance: 0.15),
                 cue: "Stop the wiggle and pull straight through the middle to form the stem.",
                 targetUVEnd: SIMD2(0.5, 0.15)),
    ])
}
