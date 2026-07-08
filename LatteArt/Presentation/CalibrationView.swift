import SwiftUI

/// Gated on the Sensor layer actually seeing the cup and pitcher tags, drawn
/// over the live camera feed `AppFlowView` renders behind every screen. Two
/// distinct targets — not one generic "align here" reticle — since the cup
/// and pitcher are different physical objects that need to land in
/// different spots for their respective AprilTags to be seen: a "Cup"
/// circle keyed to `cupDetected` (all/some of the 3 rim tags) and a
/// "Pitcher" circle keyed to `pitcherTagCount` (the spout tag, at minimum).
struct CalibrationView: View {
    @ObservedObject var model: AppFlowModel
    @ObservedObject var coordinator: CameraPourCoordinator

    @State private var showError = false

    private var cupReady: Bool { coordinator.cupDetected }
    private var pitcherReady: Bool { coordinator.pitcherTagCount >= 1 }
    private var ready: Bool { cupReady && pitcherReady }

    var body: some View {
        ZStack {
            HStack(spacing: 48) {
                reticle(label: "Cup", systemImage: "cup.and.saucer.fill", ready: cupReady)
                reticle(label: "Pitcher", systemImage: "waterbottle.fill", ready: pitcherReady)
            }
            .allowsHitTesting(false)

            VStack {
                statusCard
                    .padding(.top, 24)
                Spacer()
                nextButton
                    .padding()
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !ready { showError = true }
        }
    }

    private func reticle(label: String, systemImage: String, ready: Bool) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(ready ? .green : .white)
                    .frame(width: 140, height: 140)
                Image(systemName: ready ? "checkmark" : systemImage)
                    .font(.title)
                    .foregroundStyle(ready ? .green : .white.opacity(0.7))
            }
            Text(label)
                .font(.subheadline.bold())
                .foregroundStyle(ready ? .green : .white)
        }
    }

    @ViewBuilder private var statusCard: some View {
        VStack(spacing: 8) {
            Text("Align Your Workspace")
                .font(.title2.bold())
            Text("Put your cup in the left circle and your pitcher in the right circle so we can track their AprilTags.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            if ready {
                Label("Perfect! You're All Set.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
            } else if showError {
                Text("We can't see your cup or pitcher's tags clearly. Try adjusting the lighting or camera angle.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.white)
        .padding(.horizontal, 60)
    }

    private var nextButton: some View {
        Button {
            model.calibrationConfirmed()
        } label: {
            Text("Next")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(ready ? Color.accentColor : Color.gray.opacity(0.4),
                           in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
        }
        .disabled(!ready)
        .padding(.horizontal, 60)
    }
}
