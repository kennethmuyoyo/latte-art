import SwiftUI

/// The Presentation-owned app-flow state machine (distinct from the Simulation's
/// `PourPhase`, which is the fluid surface state). One phase per Hi-Fi screen.
enum AppPhase: Equatable {
    case splash // "Pourfect" logo
    case setup // coached onboarding sequence
    case calibrate // frame the cup/jug
    case patternSelect // choose heart/tulip/rosetta
    case beforePractice // "Follow the Guide"
    case practice // live pour + guidance/feedback
    case result // minimal completion

    /// Whether the simulated coffee disc should paint in this phase.
    var showsCoffee: Bool { self == .practice || self == .result }

    /// Scrim strength over the camera so white copy stays legible on card-heavy
    /// screens; 0 where the camera should read clearly (setup/calibrate/practice).
    var cameraScrim: Double {
        switch self {
        case .patternSelect, .beforePractice: return 0.28
        case .result: return 0.4
        default: return 0
        }
    }

    #if DEBUG
    /// Map a `LATTE_START_PHASE` env value to a phase (headless verification).
    init?(debugName: String) {
        switch debugName.lowercased() {
        case "splash": self = .splash
        case "setup": self = .setup
        case "calibrate": self = .calibrate
        case "patternselect", "pattern": self = .patternSelect
        case "beforepractice", "before": self = .beforePractice
        case "practice": self = .practice
        case "result": self = .result
        default: return nil
        }
    }
    #endif
}

/// Owns the phase, the chosen pattern, and the transitions between screens.
/// Pure UI state — it holds no Metal/AR objects (those live in `CameraStage`).
final class AppFlowModel: ObservableObject {
    @Published private(set) var phase: AppPhase = .splash
    @Published var selectedPattern: Pattern = .heart

    private func go(to next: AppPhase) {
        withAnimation(.easeInOut(duration: 0.3)) { phase = next }
    }

    // Forward intents (one per primary button in the Hi-Fi).
    func advanceFromSplash() { if phase == .splash { go(to: .setup) } }
    func finishSetup() { go(to: .calibrate) } // "I'm Ready!"
    func finishCalibration() { go(to: .patternSelect) } // "Next"
    func choose(_ pattern: Pattern) { selectedPattern = pattern; go(to: .beforePractice) } // "Start"
    func beginPractice() { go(to: .practice) } // "Begin"
    func finishPractice() { go(to: .result) }
    func tryAgain() { go(to: .practice) } // "Try Again"
    func backToPatterns() { go(to: .patternSelect) } // "Done" / "Next"

    #if DEBUG
    /// Headless verification hook (mirrors the Simulation layer's `DEMO_POUR`):
    /// `LATTE_START_PHASE=<name>` jumps straight to a screen so each can be
    /// screenshotted without tapping through. Debug-only; no effect in release.
    func applyDebugStartPhase() {
        guard let raw = ProcessInfo.processInfo.environment["LATTE_START_PHASE"],
              let p = AppPhase(debugName: raw) else { return }
        phase = p
    }
    #endif

    /// Reverse navigation (back button).
    func back() {
        switch phase {
        case .splash, .setup: break
        case .calibrate: go(to: .setup)
        case .patternSelect: go(to: .calibrate)
        case .beforePractice: go(to: .patternSelect)
        case .practice: go(to: .beforePractice)
        case .result: go(to: .patternSelect)
        }
    }
}
