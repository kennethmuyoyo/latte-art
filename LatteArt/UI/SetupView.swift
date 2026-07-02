import SwiftUI

/// Phase 1: equipment setup instructions.
struct SetupView: View {
    @ObservedObject var model: AppFlowModel

    private let steps: [(String, String)] = [
        ("camera.on.rectangle", "Mount your phone on the tripod, camera pointing straight down at the cup."),
        ("cup.and.saucer", "Center the cup in the frame on a plain surface."),
        ("drop", "Fill the jug with water. (The app simulates the coffee and milk.)"),
    ]

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text("Latte Art Trainer")
                .font(.largeTitle.bold())
            Text("Practice the pour. We simulate the crema.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 20) {
                ForEach(steps.indices, id: \.self) { i in
                    HStack(spacing: 16) {
                        Image(systemName: steps[i].0)
                            .font(.title2)
                            .frame(width: 40)
                            .foregroundStyle(.tint)
                        Text(steps[i].1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding()
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            Spacer()
            Button(action: model.begin) {
                Text("Get Started")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.tint, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .padding()
        .tint(.orange)
    }
}
