import SwiftUI

/// Hi-Fi "Logo Loading": the Pourfect wordmark on black, briefly, then it
/// auto-advances into Setup. (The wordmark is a placeholder in Figma, so we use
/// a styled text logo.)
struct SplashView: View {
    @EnvironmentObject private var flow: AppFlowModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: "cup.and.heat.waves")
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(.white)
                Text("Pourfect")
                    .appText(.title1)
                    .foregroundStyle(.white)
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            flow.advanceFromSplash()
        }
    }
}
