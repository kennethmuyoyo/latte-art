import SwiftUI

/// Hi-Fi "Align Your Workspace" — dashed cup & jug outlines over the live camera
/// so the user frames both in view. Turns green + "Perfect! You're All Set!" once
/// the cup is detected; otherwise shows the framing error.
struct CalibrationView: View {
    @EnvironmentObject private var flow: AppFlowModel
    @EnvironmentObject private var stage: CameraStage

    private var detected: Bool { stage.cupDetected }

    var body: some View {
        GeometryReader { geo in
            let pose = stage.cupViewPose
            let cupCenter = CGPoint(x: CGFloat(pose.center.x) * geo.size.width,
                                    y: CGFloat(pose.center.y) * geo.size.height)
            let cupR = max(40, CGFloat(pose.axes.x) * geo.size.width)
            let tint = detected ? Palette.correct : Color.white

            ZStack {
                // Cup + jug framing guides.
                DashedEllipse(tint: tint)
                    .frame(width: cupR * 2, height: cupR * 2)
                    .position(cupCenter)
                DashedEllipse(tint: tint.opacity(0.8))
                    .frame(width: cupR * 1.5, height: cupR * 1.5)
                    .position(x: cupCenter.x + cupR * 2.1, y: cupCenter.y)

                VStack {
                    VStack(spacing: 6) {
                        Text("Align Your Workspace")
                            .appText(.title1).foregroundStyle(.white)
                        Text("Move your cup until it fits perfectly inside the outline.")
                            .appText(.body).foregroundStyle(Palette.onCameraDim)
                            .multilineTextAlignment(.center)
                    }
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                    .padding(.top, 24)

                    Spacer()

                    VStack(spacing: 14) {
                        Text(detected
                             ? "Perfect! You're All Set!"
                             : "We can't see your cup clearly. Try adjusting the lighting or camera angle.")
                            .appText(.headline)
                            .foregroundStyle(detected ? Palette.correct : Palette.onCameraDim)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                        PillButton(title: "Next", prominent: detected, enabled: detected) {
                            flow.finishCalibration()
                        }
                    }
                    .padding(.bottom, 28)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Metrics.screenPadding)

                backButton
            }
        }
    }

    private var backButton: some View {
        VStack {
            HStack { BackButton { flow.back() }; Spacer() }
            Spacer()
        }
        .padding(16)
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
