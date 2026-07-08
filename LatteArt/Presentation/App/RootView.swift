import SwiftUI

/// The real Presentation root (replaces the temporary CameraPourView /
/// SimulationDebugView entry). One persistent `CameraStage` background stays
/// mounted for the whole session so the camera + fluid never tear down between
/// phases; the current screen is overlaid on top.
struct RootView: View {
    @StateObject private var flow = AppFlowModel()
    @StateObject private var stage: CameraStage

    init() {
        // Metal is available on device and Simulator alike; if the stack can't
        // build there is nothing to show anyway.
        _stage = StateObject(wrappedValue: CameraStage.make()!)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Persistent background: live camera (device) / neutral (sim) + fluid.
                stage.backgroundView()

                // Legibility scrim over the camera on card-heavy screens.
                Color.black.opacity(flow.phase.cameraScrim)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.3), value: flow.phase)

                // Current screen.
                screen
                    .environmentObject(flow)
                    .environmentObject(stage)
                    .transition(.opacity)
            }
            .onAppear {
                stage.viewportSize = geo.size
                #if DEBUG
                flow.applyDebugStartPhase()
                stage.setCoffeeVisible(flow.phase.showsCoffee)
                #if targetEnvironment(simulator)
                if ProcessInfo.processInfo.environment["LATTE_AUTOPOUR"] == "1" {
                    stage.startScriptedPour()
                }
                #endif
                #endif
            }
            .onChange(of: geo.size) { _, newSize in stage.viewportSize = newSize }
            .onChange(of: flow.phase) { _, phase in
                stage.setCoffeeVisible(phase.showsCoffee)
                if phase == .practice { stage.reset() }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
    }

    @ViewBuilder private var screen: some View {
        switch flow.phase {
        case .splash: SplashView()
        case .setup: SetupView()
        case .calibrate: CalibrationView()
        case .patternSelect: PatternSelectView()
        case .beforePractice: BeforePracticeView()
        case .practice: PracticeView()
        case .result: ResultView()
        }
    }
}
