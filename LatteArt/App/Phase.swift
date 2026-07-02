import Foundation

/// The app's top-level flow, per spec §2.
enum Phase: Int, CaseIterable, Equatable {
    case setup          // mount tripod, place cup, fill jug with water
    case patternSelect  // choose tulip / heart / rosetta
    case fillCup        // pour base; sim runs in cup; fill level rises
    case readyForFoam   // base ready; prompt to start the foam pour
    case formArt        // pour choreography forms the chosen pattern
    case result         // final render + score

    var title: String {
        switch self {
        case .setup:         return "Set Up"
        case .patternSelect: return "Choose a Pattern"
        case .fillCup:       return "Fill the Cup"
        case .readyForFoam:  return "Base Ready"
        case .formArt:       return "Form the Art"
        case .result:        return "Result"
        }
    }
}

/// The three patterns the user can practice.
enum LattePattern: String, CaseIterable, Identifiable {
    case heart
    case tulip
    case rosetta

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
    var symbolName: String {
        switch self {
        case .heart:   return "heart.fill"
        case .tulip:   return "leaf.fill"
        case .rosetta: return "fern"
        }
    }
}
