import SwiftUI

/// The live simulation screen, shared by fillCup / readyForFoam / formArt.
/// In the Simulator: virtual cup + touch. On device: the AR compositor renders
/// the camera + fluid behind this same overlay.
struct PourView: View {
    @ObservedObject var model: AppFlowModel
    @ObservedObject var controller: SimulationController

    /// A cup is "acquired" in the Simulator (virtual) or once the user has tapped
    /// one on device (ARKit anchor / camera detection).
    private var hasCup: Bool {
        model.renderMode == .virtual || controller.cupPose.confidence > 0
    }

    var body: some View {
        ZStack {
            // Fluid (and, on device, the camera behind it). The fluid only appears
            // once a cup is acquired — placed INTO the cup, not shown from the start.
            switch model.renderMode {
            case .arkit:
                ARFluidView(controller: controller, touchSource: model.touchSource)
                    .ignoresSafeArea()
            case .virtual:
                MetalFluidView(controller: controller, touchSource: model.touchSource)
                    .ignoresSafeArea()
            }

            if model.renderMode == .arkit, !controller.cupRegistered {
                // Onboarding: guide the user to place & lock their 3 rim dots.
                DotRegistrationOverlay(controller: controller)
                    .ignoresSafeArea()
            } else if hasCup {
                // Guidance overlay maps cup-UV to the acquired cup.
                GuidanceOverlay(pose: controller.cupPose,
                                fillLevel: controller.fillLevel,
                                showFillRing: model.phase != .formArt,
                                guide: model.phase == .formArt ? model.guide : nil)
                    .ignoresSafeArea()

                // ARKit path: surface-placement sliders, docked at the bottom.
                if model.renderMode == .arkit, controller.showTrackingDebug {
                    VStack {
                        Spacer()
                        SurfaceCalibrationOverlay(controller: controller,
                                                  onHide: { controller.showTrackingDebug = false })
                            .padding(.bottom, 80)
                    }
                }

                VStack {
                    header
                    if model.renderMode == .arkit {
                        Button("Re-place dots") { controller.resetCupRegistration() }
                            .font(.caption).padding(6)
                            .background(.black.opacity(0.4), in: Capsule())
                    }
                    Spacer()
                    footer
                }
                .padding()
            } else {
                CupAcquireOverlay()
            }
        }
    }

    @ViewBuilder private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.phase.title).font(.title3.bold())
                if model.phase == .fillCup {
                    Text("Pour to fill the cup — \(Int(controller.fillLevel * 100))%")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if model.phase == .formArt, let step = model.guide?.currentStep {
                    Text(step.note).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding()
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var footer: some View {
        switch model.phase {
        case .fillCup:
            if controller.isReadyForFoam { startFoamButton }
        case .readyForFoam:
            VStack(spacing: 10) {
                Label("Base ready", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                startFoamButton
            }
        default:
            EmptyView()
        }
    }

    private var startFoamButton: some View {
        Button(action: model.startFoamPour) {
            Text("Start the Foam Pour")
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.orange, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

/// Shown over the live camera until a cup is acquired. Non-interactive so taps
/// pass through to the Metal view, which places the cup where the user taps.
private struct CupAcquireOverlay: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            // Framing reticle centered in the view.
            Circle()
                .strokeBorder(.white.opacity(0.85), style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                .frame(width: 240, height: 240)
                .scaleEffect(pulse ? 1.04 : 0.96)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)

            VStack {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "hand.tap.fill").font(.title)
                    Text("Tap your cup").font(.headline)
                    Text("Point the camera down at the cup, then tap it on screen to drop the coffee in.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                .padding(.bottom, 60)
            }
        }
        .allowsHitTesting(false)
        .onAppear { pulse = true }
    }
}
