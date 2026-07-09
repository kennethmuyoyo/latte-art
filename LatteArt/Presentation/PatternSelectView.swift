import SwiftUI

/// "Choose Your Pattern" — 3 pattern cards, each with its own Start button —
/// tapping one jumps straight into that pattern's pre-practice guide.
struct PatternSelectView: View {
    @ObservedObject var model: AppFlowModel

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text("Choose Your Pattern")
                    .appText(.title1).foregroundStyle(.white)
                Text("Master the fundamentals, one pour at a time.")
                    .appText(.body).foregroundStyle(Palette.onCameraDim)
            }
            .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
            .padding(.top, 20)

            Spacer()

            HStack(alignment: .top, spacing: Metrics.cardSpacing) {
                ForEach(LattePattern.allCases) { pattern in
                    PatternCardView(
                        title: pattern.displayName,
                        blurb: pattern.subtitle,
                        level: pattern.level,
                        imageName: pattern.thumbnailAssetName,
                        isSelected: model.selectedPattern == pattern
                    ) { model.choose(pattern) }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Metrics.screenPadding)
    }
}
