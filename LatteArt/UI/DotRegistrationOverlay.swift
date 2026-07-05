import SwiftUI

/// Onboarding for the yellow-dot cup: the user taps the 3 rim dots they see on
/// the camera to register the cup (no autodetection). Shows the tapped points and
/// a reset. Taps pass through to the ARSCNView (this layer is non-interactive
/// except the reset button). Shown until `controller.cupRegistered` is true.
struct DotRegistrationOverlay: View {
    @ObservedObject var controller: SimulationController

    private var count: Int { controller.tappedPoints.count }

    var body: some View {
        ZStack {
            // Markers at the tapped points (non-interactive → taps reach ARKit).
            Canvas { ctx, _ in
                for (i, p) in controller.tappedPoints.enumerated() {
                    let rect = CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)
                    ctx.stroke(Circle().path(in: rect), with: .color(.yellow), lineWidth: 3)
                    ctx.draw(Text("\(i + 1)").font(.caption2.bold()).foregroundColor(.yellow),
                             at: CGPoint(x: p.x, y: p.y - 20))
                }
            }
            .allowsHitTesting(false)

            VStack {
                VStack(spacing: 6) {
                    Image(systemName: "hand.tap.fill").font(.title)
                    Text("Tap your 3 rim dots").font(.headline)
                    Text("Tap each yellow dot on the cup's rim as you see it on screen.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("\(count) / 3 placed")
                        .font(.subheadline.monospaced().bold())
                        .foregroundStyle(count >= 3 ? .green : .orange)
                }
                .padding()
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                .allowsHitTesting(false)

                Spacer()

                if count > 0 {
                    Button("Start over") { controller.resetCupRegistration() }
                        .font(.subheadline).padding(10)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(.bottom, 40)
                }
            }
            .padding()
        }
    }
}
