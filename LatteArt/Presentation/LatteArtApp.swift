import SwiftUI

// ============================================================================
// TEMPORARY DEBUG ENTRY POINT.
//
// The WindowGroup is pointed at `SimulationDebugView` so the Simulation layer
// can be exercised and visually verified on its own (touch / scripted pour →
// physics → fluid → render). Revert this to the real Presentation root when the
// UI layer (Ellie) lands.
// ============================================================================
@main
struct LatteArtApp: App {
    var body: some Scene { WindowGroup { SimulationDebugView() } }
}

#Preview {
	SimulationDebugView()
}
