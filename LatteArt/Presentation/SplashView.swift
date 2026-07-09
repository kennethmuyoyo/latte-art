import SwiftUI

/// "Logo Loading" — the wordmark on black, briefly, then auto-advances into
/// Setup.
struct SplashView: View {
    @ObservedObject var model: AppFlowModel

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
            model.advanceFromSplash()
        }
    }
}
