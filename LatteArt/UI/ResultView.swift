import SwiftUI

/// Phase 6: show the finished pattern render and a score.
struct ResultView: View {
    @ObservedObject var model: AppFlowModel

    var body: some View {
        VStack(spacing: 24) {
            Text("Result").font(.largeTitle.bold()).padding(.top, 40)

            // Final still of the sim output (the fluid already renders as a
            // circle inside its own square view, so no rim overlay is needed).
            MetalFluidView(controller: model.controller, touchSource: model.touchSource)
                .disabled(true)
                .frame(width: 300, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 20))

            if let score = model.finalScore {
                VStack(spacing: 6) {
                    Text("\(score)").font(.system(size: 64, weight: .bold))
                    Text(scoreBlurb(score)).foregroundStyle(.secondary)
                }
            }

            Text("Pattern: \(model.selectedPattern.displayName)")
                .foregroundStyle(.secondary)

            Spacer()
            Button(action: model.restart) {
                Text("Practice Again")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.orange, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .padding()
    }

    private func scoreBlurb(_ score: Int) -> String {
        switch score {
        case 85...: return "Barista-level pour!"
        case 65..<85: return "Nice — the pattern is coming through."
        case 40..<65: return "Getting there. Watch the target ring."
        default: return "Keep practicing the pour path."
        }
    }
}
