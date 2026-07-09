import Foundation

/// The app's top-level flow state. Distinct from `PourPhase` (Simulation's
/// idle/mixing/drawing physics regime) — this is what screen we're on.
enum Phase {
    case splash
    case setup
    case calibration
    case patternSelect
    case preGuide
    case practice
    case result
}

/// The 3 basic latte art patterns, with the copy from the design spec.
enum LattePattern: String, CaseIterable, Identifiable {
    case heart, tulip, rosetta

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .heart: return "Heart"
        case .tulip: return "Tulip"
        case .rosetta: return "Rosetta"
        }
    }

    /// Card subtitle on Pattern Selection.
    var subtitle: String {
        switch self {
        case .heart: return "The first step to every great latte artist."
        case .tulip: return "Learn timing and layered pours."
        case .rosetta: return "Build rhythm, precision, and flow."
        }
    }

    /// Difficulty badge shown on the pattern card ("Lv N").
    var level: Int {
        switch self {
        case .heart: return 1
        case .tulip: return 2
        case .rosetta: return 3
        }
    }

    /// The full pouring technique, shown on the Pre-Guide screen before
    /// practice begins. Matches the choreography in `PatternLibrary` — the
    /// blend/base phase is skipped (practice starts on a pre-filled base, see
    /// `LevelModel.baseFillFraction`), so these start at the drawing motion.
    var instructions: String {
        switch self {
        case .heart:
            return "Lower the pitcher close to the surface and pour steadily in one spot — the milk parts the surface and spreads into a circle that blooms toward you. When the circle has formed, lift the pitcher slightly and cut straight through it toward yourself in one motion; the exit of the stroke pulls the circle into the heart's point."
        case .tulip:
            return "The tulip is made by stacking several small pours on top of one another. Lower the pitcher close to the surface and make a short pour to create the first petal. Repeat this, each pour slightly pushing into the previous one. Finish by pulling the pitcher through the center to connect all the layers into a tulip."
        case .rosetta:
            return "The rosetta combines a gentle side-to-side motion with a steady backward movement. Lower the pitcher close to the surface, then gently wiggle it left and right while slowly moving backward to create the leaf-like layers. Once the pattern is complete, stop the wiggle and pull the pitcher through the center to form the stem."
        }
    }

    /// Asset catalog image set name — see `Assets.xcassets`.
    var thumbnailAssetName: String {
        switch self {
        case .heart: return "PatternHeart"
        case .tulip: return "PatternTulip"
        case .rosetta: return "PatternRosetta"
        }
    }
}
