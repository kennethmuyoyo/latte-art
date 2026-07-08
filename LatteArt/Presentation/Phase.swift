import Foundation

/// The app's top-level flow state. Distinct from `PourPhase` (Simulation's
/// idle/mixing/drawing physics regime) — this is what screen we're on.
enum Phase {
    case setup
    case calibration
    case patternSelect
    case preGuide
    case practice
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

    /// Asset catalog image set name — see `Assets.xcassets`.
    var thumbnailAssetName: String {
        switch self {
        case .heart: return "PatternHeart"
        case .tulip: return "PatternTulip"
        case .rosetta: return "PatternRosetta"
        }
    }
}
