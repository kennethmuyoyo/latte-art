import SwiftUI

// ============================================================================
// On device: `AppFlowView` — the real onboarding → calibration → pattern
// select → coached practice flow, backed by `AppFlowModel`.
// In the Simulator: there's no camera/ARKit, so fall back to
// `SimulationDebugView` (touch / scripted pour) to exercise the Simulation
// layer on its own.
// ============================================================================
@main
struct LatteArtApp: App {
    @Environment(\.scenePhase) private var scenePhase

    #if !targetEnvironment(simulator)
    @StateObject private var model = AppFlowModel()
    #endif

    var body: some Scene {
        WindowGroup {
            #if targetEnvironment(simulator)
            SimulationDebugView()
            #else
            AppFlowView(model: model)
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
                .statusBarHidden(true)
            #endif
        }
        // The user's hands are on the pitcher, not the screen — keep the
        // display awake while the app is in the foreground.
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = (phase == .active)
        }
    }
}

#Preview {
	SimulationDebugView()
}
