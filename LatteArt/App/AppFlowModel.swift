import SwiftUI
import Combine
import ARKit

/// How the live pour screen renders + tracks the cup.
enum RenderMode {
    case arkit    // LiDAR device: ARSCNView + yellow-dot cup tracking (the real experience)
    case virtual  // Simulator / no ARKit: centered virtual cup + touch
}

/// Owns the app's phase state machine and coordinates the simulation, the pour
/// source, and the pattern guide across phases (spec §2).
final class AppFlowModel: ObservableObject {
    @Published var phase: Phase = .setup
    @Published var selectedPattern: LattePattern = .rosetta
    @Published var guide: PatternGuide?
    @Published var finalScore: Int?

    let controller: SimulationController
    let touchSource = TouchPourSource()

    /// Which render/track path this device uses (chosen once at launch).
    let renderMode: RenderMode

    private var cancellables = Set<AnyCancellable>()

    /// Demo mode (env `LATTEART_DEMO=1`): drive with a scripted circular pour and
    /// jump straight into filling, so the sim can be seen/screenshotted hands-free.
    private let demoSource = AutoPourSource()
    private var isDemo: Bool { ProcessInfo.processInfo.environment["LATTEART_DEMO"] == "1" }

    init(ctx: MetalContext) {
        controller = SimulationController(ctx: ctx)
        controller.use(pourSource: touchSource)

        #if targetEnvironment(simulator)
        renderMode = .virtual
        #else
        // The real experience needs ARKit (LiDAR dot tracking); fall back to the
        // virtual cup on any device without world tracking so the app still runs.
        if ARWorldTrackingConfiguration.isSupported {
            renderMode = .arkit
            controller.isCameraDriven = true   // gate fluid/pours until the cup is locked
        } else {
            renderMode = .virtual
        }
        #endif

        // Drive the pattern guide from the sim's frame loop.
        controller.onAdvance = { [weak self] dt, pour in
            guard let self, let guide = self.guide, self.phase == .formArt else { return }
            guide.tick(dt: dt)
            guide.evaluate(pour)
            if guide.finished {
                DispatchQueue.main.async { self.finishArt() }
            }
        }

        // Auto-advance fill → ready-for-foam when the cup is full enough.
        controller.$isReadyForFoam
            .receive(on: RunLoop.main)
            .sink { [weak self] ready in
                guard let self else { return }
                if ready, self.phase == .fillCup {
                    self.phase = .readyForFoam
                    // In demo mode, roll straight into the foam pour to show it off.
                    if self.isDemo {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            if self.phase == .readyForFoam { self.startFoamPour() }
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Transitions

    /// Call once the view appears to optionally enter demo mode.
    func startIfDemo() {
        guard isDemo, phase == .setup else { return }
        selectedPattern = .rosetta
        controller.reset()
        controller.mode = .fill
        controller.use(pourSource: demoSource)
        phase = .fillCup
    }

    func begin() {
        phase = .patternSelect
    }

    func choose(_ pattern: LattePattern) {
        selectedPattern = pattern
        controller.reset()
        controller.mode = .fill
        phase = .fillCup
    }

    func startFoamPour() {
        let choreo = PatternLibrary.choreography(for: selectedPattern)
        let g = PatternGuide(choreography: choreo)
        guide = g
        controller.mode = .foam
        phase = .formArt
    }

    func finishArt() {
        controller.mode = .idle
        finalScore = guide?.score
        phase = .result
    }

    func restart() {
        controller.reset()
        controller.releaseCup()   // re-acquire the cup for the next run (device)
        guide?.reset()
        guide = nil
        finalScore = nil
        controller.mode = .fill
        phase = .patternSelect
    }
}
