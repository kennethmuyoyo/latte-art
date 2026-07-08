import SwiftUI

/// "Follow the Guide" card over the live camera feed `AppFlowView` renders
/// behind every screen — the last stop before Practice.
struct PreGuideView: View {
    @ObservedObject var model: AppFlowModel
    @ObservedObject var coordinator: CameraPourCoordinator

    private let bullets = [
        "Keep your pitcher aligned with the AR path",
        "Pour steadily",
        "Watch the arrows",
        "Trust the rhythm",
    ]

    var body: some View {
        VStack(spacing: 20) {
            Text("Follow the Guide")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 10) {
                ForEach(bullets, id: \.self) { bullet in
                    Label(bullet, systemImage: "checkmark.circle")
                        .font(.subheadline)
                }
            }

            Button {
                model.beginPractice()
            } label: {
                Text("Begin")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
        }
        .padding(24)
        .foregroundStyle(.white)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 60)
    }
}
