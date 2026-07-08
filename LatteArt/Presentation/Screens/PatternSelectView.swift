import SwiftUI

/// Hi-Fi "Choose your pattern" — a frosted title over the camera with the three
/// pattern cards (Heart / Tulip / Rosetta), each with a preview, blurb and Start.
struct PatternSelectView: View {
    @EnvironmentObject private var flow: AppFlowModel

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
                ForEach(Pattern.all) { pattern in
                    PatternCardView(
                        title: pattern.name,
                        blurb: pattern.blurb,
                        level: pattern.level,
                        imageName: pattern.imageName,
                        isSelected: flow.selectedPattern.id == pattern.id
                    ) { flow.choose(pattern) }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Metrics.screenPadding)
        .overlay(alignment: .topLeading) {
            BackButton { flow.back() }.padding(16)
        }
    }
}
