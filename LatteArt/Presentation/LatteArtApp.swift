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
    #if !targetEnvironment(simulator)
    @StateObject private var model = AppFlowModel()
    #endif

    var body: some Scene {
        WindowGroup {
            #if targetEnvironment(simulator)
            SimulationDebugView()
            #else
            AppFlowView(model: model)
            #endif
        }
    }
}

#Preview {
	SimulationDebugView()
}
