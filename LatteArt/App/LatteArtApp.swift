import SwiftUI

@main
struct LatteArtApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Root: builds the Metal stack once and hands it to the flow. If Metal is
/// unavailable (shouldn't happen on supported targets) we show a message rather
/// than crash.
struct RootView: View {
    var body: some View {
        if let ctx = MetalContext() {
            AppFlowView(ctx: ctx)
        } else {
            Text("This device does not support Metal.")
                .foregroundStyle(.secondary)
                .padding()
        }
    }
}
