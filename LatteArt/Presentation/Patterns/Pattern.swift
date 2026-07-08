import Foundation
import simd

// Patterns are DATA, not code (spec.md §8): a pattern is a name + blurb + an
// ordered pour "choreography". The guidance overlay renders the current step's
// target/arrow and its cue; adding a pattern is just another `Pattern` value,
// no solver or UI changes. Coordinates are `CupSpace` UV (center (0.5,0.5),
// rim radius 0.5, y-down) — the same space the Sensor/Simulation layers speak.

/// One movement in a pattern's choreography.
struct PourStep: Equatable {
    /// Coaching line shown in the cue pill (from the Hi-Fi "During Practice" copy).
    let cue: String
    /// Where to aim the pour on the cup surface, `CupSpace` UV.
    let targetUV: SIMD2<Float>
    /// Direction the pour should travel, `CupSpace` UV (drawn as the guide arrow).
    let direction: SIMD2<Float>
    /// How long to dwell on this step before the guidance auto-advances (seconds).
    let duration: TimeInterval
    /// A back-and-forth "wiggle" step (rosetta) — the arrow animates side to side.
    var wiggle: Bool = false
}

struct Pattern: Identifiable, Equatable {
    let id: String
    let name: String
    let blurb: String
    let level: Int
    /// Asset-catalog name for the preview photo (falls back to a placeholder).
    let imageName: String
    let steps: [PourStep]
}

extension Pattern {
    /// Heart — "The first step to every great latte artist." Pour steadily → slow
    /// down → pull through.
    static let heart = Pattern(
        id: "heart", name: "Heart", blurb: "The first step to every great latte artist.",
        level: 1, imageName: "pattern-heart",
        steps: [
            PourStep(cue: "Pour steadily", targetUV: [0.5, 0.44], direction: [0, 1], duration: 3.0),
            PourStep(cue: "Slow down", targetUV: [0.5, 0.5], direction: [0, 1], duration: 2.5),
            PourStep(cue: "Pull through", targetUV: [0.5, 0.36], direction: [0, 1], duration: 2.5),
        ]
    )

    /// Tulip — "Learn timing and layered pours." Pour · pause · stack · finish.
    static let tulip = Pattern(
        id: "tulip", name: "Tulip", blurb: "Learn timing and layered pours.",
        level: 2, imageName: "pattern-tulip",
        steps: [
            PourStep(cue: "Pour", targetUV: [0.5, 0.5], direction: [0, 1], duration: 2.0),
            PourStep(cue: "Pause", targetUV: [0.5, 0.5], direction: [0, 1], duration: 1.5),
            PourStep(cue: "Stack", targetUV: [0.5, 0.46], direction: [0, 1], duration: 2.0),
            PourStep(cue: "Finish", targetUV: [0.5, 0.36], direction: [0, 1], duration: 2.0),
        ]
    )

    /// Rosetta — "Build rhythm, precision, and flow." Wiggle → slow down → pull through.
    static let rosetta = Pattern(
        id: "rosetta", name: "Rosetta", blurb: "Build rhythm, precision, and flow.",
        level: 3, imageName: "pattern-rosetta",
        steps: [
            PourStep(cue: "Start your wiggle", targetUV: [0.5, 0.4], direction: [0, 1], duration: 3.5, wiggle: true),
            PourStep(cue: "Slow down", targetUV: [0.5, 0.5], direction: [0, 1], duration: 2.0),
            PourStep(cue: "Pull through", targetUV: [0.5, 0.34], direction: [0, 1], duration: 2.5),
        ]
    )

    static let all: [Pattern] = [.heart, .tulip, .rosetta]
}

// MARK: - Wrong-pour feedback lines (Hi-Fi "When they did a Wrong Pour ❌")

enum WrongPourFeedback {
    static let lines = [
        "Too fast. Pour closer to the surface.",
        "Keep a steady pace.",
        "Your pitcher is too high.",
        "Try a smoother motion.",
        "Follow the guide. Almost there.",
    ]
}
