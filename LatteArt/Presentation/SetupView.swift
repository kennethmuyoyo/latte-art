import SwiftUI

/// "Let's Set Up!" — a coached onboarding sequence over the live camera feed
/// `AppFlowView` renders behind every screen: a white line-art icon + caption
/// per step, paged with "Next" until the last step's "I'm Ready!".
struct SetupView: View {
    @ObservedObject var model: AppFlowModel
    @State private var step = 0

    private struct Hint { let icon: String; let caption: String }
    private let hints: [Hint] = [
        Hint(icon: "iphone.gen3", caption: "Something to put your phone up"),
        Hint(icon: "cup.and.saucer", caption: "Cup and jug filled with water"),
        Hint(icon: "lightbulb", caption: "Find a place with good lighting"),
        Hint(icon: "camera.viewfinder", caption: "Position your phone on a stand.\nCamera pointing straight down at the cup & jug."),
    ]

    private var isLast: Bool { step == hints.count - 1 }

    var body: some View {
        VStack {
            Text("Let's Set Up!")
                .appText(.title1)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                .padding(.top, 24)

            Spacer()
            OnboardingHint(systemIcon: hints[step].icon, caption: hints[step].caption)
                .id(step)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            Spacer()

            VStack(spacing: 16) {
                PageDots(count: hints.count, index: step)
                PillButton(title: isLast ? "I'm Ready!" : "Next") {
                    if isLast { model.readyForCalibration() }
                    else { withAnimation(.easeInOut(duration: 0.25)) { step += 1 } }
                }
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Small page indicator dots.
struct PageDots: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == index ? Color.white : Palette.onCameraFaint)
                    .frame(width: 7, height: 7)
            }
        }
    }
}
