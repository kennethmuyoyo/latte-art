import SwiftUI

/// "Align Your Workspace" — gated on the Sensor layer actually seeing the cup
/// and pitcher tags, drawn over the live camera feed `AppFlowView` renders
/// behind every screen. Two distinct targets — not one generic "align here"
/// reticle — since the cup and pitcher are different physical objects that
/// need to land in different spots for their respective AprilTags to be
/// seen: a "Cup" circle keyed to `cupDetected` (the 3 rim tags) and a
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
                VStack(spacing: 6) {
                    Text("Align Your Workspace")
                        .appText(.title1).foregroundStyle(.white)
                    Text("Put your cup in the left circle and your pitcher in the right circle so we can track their AprilTags.")
                        .appText(.body).foregroundStyle(Palette.onCameraDim)
                        .multilineTextAlignment(.center)
                }
                .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                .padding(.top, 24)

                Spacer()

                VStack(spacing: 14) {
                    Text(statusText)
                        .appText(.headline)
                        .foregroundStyle(ready ? Palette.correct : Palette.onCameraDim)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    PillButton(title: "Next", prominent: ready, enabled: ready) {
                        model.calibrationConfirmed()
                    }
                }
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Metrics.screenPadding)
        }
        .task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !ready { showError = true }
        }
    }

    private var statusText: String {
        if ready { return "Perfect! You're All Set!" }
        if showError { return "We can't see your cup or pitcher's tags clearly. Try adjusting the lighting or camera angle." }
        return "Move your cup and pitcher until they fit inside the outlines."
    }

    private func reticle(label: String, systemImage: String, ready: Bool) -> some View {
        VStack(spacing: 10) {
            DashedEllipse(tint: ready ? Palette.correct : .white)
                .frame(width: 140, height: 140)
                .overlay(
                    Image(systemName: ready ? "checkmark" : systemImage)
                        .font(.title)
                        .foregroundStyle(ready ? Palette.correct : .white.opacity(0.7))
                )
            Text(label)
                .appText(.headlineBold)
                .foregroundStyle(ready ? Palette.correct : .white)
        }
    }
}

/// A dashed ellipse outline used as a placement guide.
struct DashedEllipse: View {
    var tint: Color = .white
    var body: some View {
        Ellipse()
            .strokeBorder(tint, style: StrokeStyle(lineWidth: 2.5, dash: [10, 8]))
            .shadow(color: .black.opacity(0.35), radius: 3)
    }
}
