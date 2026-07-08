import SwiftUI

// Real Presentation entry point. `RootView` owns the persistent camera + fluid
// stage (device: ARKit + AprilTag; Simulator: neutral backdrop + touch) and the
// app-flow state machine that overlays each screen on top.
@main
struct LatteArtApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
