import simd

/// The 3 pattern choreographies. Coaching `note` text is verbatim from the
/// design spec's "During Practice" copy. Target UVs/directions/durations are
/// a reasonable first pass, NOT measured against real pour footage — expect
/// to retune these once testing on the physical rig (same category as the
/// tilt/occlusion constants elsewhere in Sensor/Simulation).
enum PatternLibrary {
    static func choreography(for pattern: LattePattern) -> PourChoreography {
        switch pattern {
        case .heart: return heart
        case .tulip: return tulip
        case .rosetta: return rosetta
        }
    }

    /// Steady center pour to build the base, then a straight pull through the
    /// near rim to draw the heart's point.
    private static let heart = PourChoreography(pattern: .heart, steps: [
        PourStep(targetUV: SIMD2(0.5, 0.42), direction: .zero, duration: 3.0, note: "Pour steadily."),
        PourStep(targetUV: SIMD2(0.5, 0.55), direction: .zero, duration: 1.5, note: "Slow down."),
        PourStep(targetUV: SIMD2(0.5, 0.85), direction: SIMD2(0, 1), duration: 1.0, note: "Pull through."),
    ])

    /// A held pour, a brief pause, a second pour stacked closer to the rim,
    /// then a pull-through to finish — the layered "stack" look.
    private static let tulip = PourChoreography(pattern: .tulip, steps: [
        PourStep(targetUV: SIMD2(0.5, 0.35), direction: .zero, duration: 1.2, note: "Pour."),
        PourStep(targetUV: SIMD2(0.5, 0.40), direction: .zero, duration: 0.6, note: "Pause."),
        PourStep(targetUV: SIMD2(0.5, 0.55), direction: .zero, duration: 1.2, note: "Stack."),
        PourStep(targetUV: SIMD2(0.5, 0.85), direction: SIMD2(0, 1), duration: 1.0, note: "Finish."),
    ])

    /// A wiggling center pour that slows as it builds layers, then a
    /// straight pull through the rim.
    private static let rosetta = PourChoreography(pattern: .rosetta, steps: [
        PourStep(targetUV: SIMD2(0.5, 0.40), direction: .zero, duration: 2.0, note: "Start your wiggle."),
        PourStep(targetUV: SIMD2(0.5, 0.60), direction: .zero, duration: 1.2, note: "Slow down."),
        PourStep(targetUV: SIMD2(0.5, 0.85), direction: SIMD2(0, 1), duration: 1.0, note: "Pull through."),
    ])
}
