import SwiftUI

/// Minimal completion screen (kept intentionally light, per the user — the Hi-Fi
/// has no dedicated result frame). The finished pour stays visible behind a small
/// card offering another attempt or a new pattern.
struct ResultView: View {
    @EnvironmentObject private var flow: AppFlowModel

    var body: some View {
        ZStack {
            GlassCard {
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Palette.correct)
                    Text("Nice work!")
                        .appText(.title2).foregroundStyle(.white)
                    Text("You finished the \(flow.selectedPattern.name).")
                        .appText(.body).foregroundStyle(Palette.onCameraDim)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 12) {
                        PillButton(title: "New Pattern", prominent: false) { flow.backToPatterns() }
                        PillButton(title: "Try Again") { flow.tryAgain() }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(width: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
