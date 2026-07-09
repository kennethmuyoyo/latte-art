import SwiftUI

/// Minimal completion screen shown once a pattern's choreography genuinely
/// finishes (`PatternGuide.finished`, which now only happens after real
/// sustained on-track pouring — see `PatternGuide.advance`). The finished
/// pour stays visible behind a small card offering another attempt or a new
/// pattern.
struct ResultView: View {
    @ObservedObject var model: AppFlowModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            GlassCard {
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Palette.correct)
                    Text("Nice work!")
                        .appText(.title2).foregroundStyle(.white)
                    if let pattern = model.selectedPattern {
                        Text("You finished the \(pattern.displayName).")
                            .appText(.body).foregroundStyle(Palette.onCameraDim)
                            .multilineTextAlignment(.center)
                    }

                    HStack(spacing: 12) {
                        PillButton(title: "New Pattern", prominent: false) { model.backToPatterns() }
                        PillButton(title: "Try Again") { model.tryAgain() }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(width: 320)
        }
    }
}
