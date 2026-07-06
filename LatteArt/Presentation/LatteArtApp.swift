import SwiftUI

// ============================================================================
// TEMPORARY ENTRY POINT.
//
// On device: `CameraPourView` — the real integration path (AprilTag pitcher/cup
// tracking → PourSample → physics → fluid → composited on the live camera).
// In the Simulator: there's no camera/ARKit, so fall back to `SimulationDebugView`
// (touch / scripted pour) to exercise the Simulation layer on its own.
// Revert to the real Presentation root when the UI layer (Ellie) lands.
// ============================================================================
@main
struct LatteArtApp: App {
    var body: some Scene {
        WindowGroup {
            #if targetEnvironment(simulator)
            SimulationDebugView()
            #else
            CameraPourView()
            #endif
        }
    }
}

#Preview {
	SimulationDebugView()
}
