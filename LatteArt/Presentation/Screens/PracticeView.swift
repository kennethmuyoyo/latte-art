import SwiftUI
import simd

/// Hi-Fi "During Practice" — the live camera + simulated coffee with the guidance
/// arrow, the dark cue pill (green on-track / red on a wrong pour), and a back
/// button. In the Simulator, drag to pour; on device the AprilTag pitcher drives it.
struct PracticeView: View {
    @EnvironmentObject private var flow: AppFlowModel
    @EnvironmentObject private var stage: CameraStage

    @State private var stepIndex = 0
    @State private var stepElapsed: Double = 0
    @State private var finished = false
    @State private var tone: CueTone = .neutral
    @State private var wrongIndex = 0

    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private var pattern: Pattern { flow.selectedPattern }
    private var step: PourStep { pattern.steps[min(stepIndex, pattern.steps.count - 1)] }

    private var cueText: String {
        if finished { return "Nice pour!" }
        if tone == .wrong { return WrongPourFeedback.lines[wrongIndex % WrongPourFeedback.lines.count] }
        return step.cue
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Touch-to-pour capture (Simulator; harmless on device).
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in stage.touch(atViewPoint: g.location, viewport: geo.size) }
                            .onEnded { _ in stage.touchEnded() }
                    )

                // Green guidance arrow on the cup surface.
                GuidanceCanvas(pose: stage.cupViewPose, step: step, active: !finished)
                    .allowsHitTesting(false)

                // Cue / feedback pill, and the Done button when the pattern is complete.
                VStack {
                    CuePill(text: cueText, tone: finished ? .correct : tone)
                        .animation(.easeInOut(duration: 0.2), value: cueText)
                        .padding(.top, 16)
                    Spacer()
                    if finished {
                        PillButton(title: "Done") { flow.finishPractice() }
                            .padding(.bottom, 22)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                BackButton { flow.back() }.padding(16)
            }
        }
        .onReceive(tick) { _ in advanceCoaching(dt: 0.1) }
    }

    /// One coaching tick: update the on-track/wrong feedback and advance steps.
    private func advanceCoaching(dt: Double) {
        guard !finished else { return }

        if let uv = stage.currentPour?.uv {
            let d = simd_distance(uv, step.targetUV)
            let onTrack = d < 0.18
            if !onTrack && tone != .wrong { wrongIndex += 1 }
            tone = onTrack ? .correct : .wrong
        } else {
            tone = .neutral
        }

        stepElapsed += dt
        if stepElapsed >= step.duration {
            stepElapsed = 0
            if stepIndex + 1 < pattern.steps.count {
                withAnimation { stepIndex += 1 }
            } else {
                withAnimation { finished = true }
            }
        }
    }
}
