import SwiftUI
import simd

/// The main coached screen: live AR + fluid render (unchanged composited
/// disc), a back button, and a step-by-step instruction card at the top —
/// no on-screen arrow. The guidance IS the real technique's own directions
/// ("pour into the center...", "hold steady...", "pull through..."), shown
/// as text and advanced one at a time as each is actually completed
/// (`PatternGuide.advance` only counts a step done while genuinely on-track,
/// not on a timer) — the spatial arrow this replaced kept fighting the real
/// pour motion instead of describing it.
struct PracticeView: View {
    @ObservedObject var model: AppFlowModel
    @ObservedObject var coordinator: CameraPourCoordinator
    @ObservedObject var guide: PatternGuide

    @State private var showDebugHUD = false

    /// `.neutral` until a live pour sample has actually arrived (`lastUV` is
    /// only ever set once one has — see `PatternGuide.advance`), then tracks
    /// the engine's real on-track/off-track judgment.
    private var tone: CueTone {
        guard guide.lastUV != nil else { return .neutral }
        return guide.isError ? .wrong : .correct
    }

    var body: some View {
        VStack {
            // Fixed-width, centered card matching every other GlassCard in
            // the app (PreGuideView/ResultView both use exactly this
            // 320pt-wide convention) — this was stretched full-bleed with
            // its own ad hoc padding before, which is why it read as a
            // different visual language from the rest of the app.
            StepGuideCard(guide: guide, tone: tone)
                .frame(width: 320)
                .padding(.top, 16)
            Spacer()
            if showDebugHUD {
                PourDebugHUD(coordinator: coordinator)
                    .allowsHitTesting(false)
            }
        }
        .padding()
        // Without an explicit full-screen frame here, this VStack sizes
        // itself to fit its content — so toggling the (sizable) debug HUD
        // on/off changed how big it wanted to be, and since the back/debug
        // buttons are anchored to ITS corners via `.overlay(alignment:)`,
        // they visibly moved inward whenever the HUD was hidden. Forcing
        // this to always fill the available space keeps those corners fixed
        // regardless of what's showing inside.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            BackButton { model.exitPractice() }.padding(16)
        }
        .overlay(alignment: .topTrailing) {
            debugToggleButton.padding(16)
        }
    }

    private var debugToggleButton: some View {
        Button {
            showDebugHUD.toggle()
        } label: {
            Image(systemName: showDebugHUD ? "ladybug.fill" : "ladybug")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Palette.onCameraFaint, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

}

/// The actual guidance: a step counter + the current step's full instruction
/// text (not a terse label — the real technique's own words), advancing one
/// step at a time as each is genuinely completed. Tone-tinted (neutral until
/// a live pour arrives, then green/red) the same way the old cue pill was,
/// just in a card roomy enough for full sentences instead of a one-line pill.
private struct StepGuideCard: View {
    @ObservedObject var guide: PatternGuide
    let tone: CueTone

    private var stepCount: Int { guide.choreography.steps.count }

    private var tint: Color {
        switch tone {
        case .neutral: return .white
        case .correct: return Palette.correct
        case .wrong: return Palette.wrong
        }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Step \(min(guide.currentIndex + 1, stepCount)) of \(stepCount)")
                        .appText(.small)
                        .foregroundStyle(Palette.onCameraDim)
                    Spacer()
                    switch tone {
                    case .correct: Image(systemName: "checkmark.circle.fill").foregroundStyle(tint)
                    case .wrong: Image(systemName: "xmark.circle.fill").foregroundStyle(tint)
                    case .neutral: EmptyView()
                    }
                }
                Text(guide.message)
                    .appText(.bodyBold)
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: guide.message)
    }
}

/// Live diagnostics for "I'm tilting the pitcher and nothing is happening":
/// shows exactly which pitcher tags are seen, whether the spout is inside the
/// cup rim (a silent way pouring gets suppressed), the raw tilt angle against
/// the actual threshold that gates any flow at all (`PourPhysics.thetaStart`
/// — note this is NOT the same as `AprilTagPourSource`'s own legacy
/// `restAngle`, which `PourPhysics.derive` ignores in favor of its own
/// curve), and the derived flow/float-fraction/fill readouts.
private struct PourDebugHUD: View {
    @ObservedObject var coordinator: CameraPourCoordinator
    @ObservedObject var controller: SimulationController

    init(coordinator: CameraPourCoordinator) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _controller = ObservedObject(wrappedValue: coordinator.controller)
    }

    private let thetaStartDegrees = PourPhysics().thetaStart * 180 / .pi
    private let thetaMaxDegrees = PourPhysics().thetaMax * 180 / .pi

    private func tagLine() -> String {
        var spout = coordinator.pitcherTagsDetected.contains(AprilTagRoles.pitcherSpoutID) ? "✓" : "✗"
        if coordinator.spoutReconstructed { spout += "(reconstructed)" }
        let refs = AprilTagRoles.pitcherReferenceIDs.map {
            coordinator.pitcherTagsDetected.contains($0) ? "\($0)✓" : "\($0)✗"
        }.joined(separator: " ")
        return "Spout(\(AprilTagRoles.pitcherSpoutID))\(spout)  Ref: \(refs)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tagLine())
            Text(coordinator.debugLine)
                .foregroundStyle(.yellow)
            Text(coordinator.pourDebugLine)
                .foregroundStyle(.cyan)
            if !coordinator.spoutOverCup {
                Text("⚠︎ spout is outside the cup rim — pour suppressed")
                    .foregroundStyle(.orange)
            }
            if !controller.stats.hasSample {
                Text("no pour sample — spout not detected, or cup not tracked")
                    .foregroundStyle(.orange)
            } else {
                Text(String(format: "tilt %.0f° (need >%.0f°, maxes out %.0f°)",
                            controller.stats.tiltDegrees, thetaStartDegrees, thetaMaxDegrees))
                Text(String(format: "flow %.1f ml/s   φ %.2f   Fr %.2f   h %.3fm",
                            controller.stats.flow, controller.stats.phi,
                            controller.stats.froude, controller.stats.height))
                Text(String(format: "landing (%.2f, %.2f)",
                            controller.stats.landingUV.x, controller.stats.landingUV.y))
            }
            Text(String(format: "fill %.0f%%   %@", controller.fillFraction * 100,
                        String(describing: controller.phase)))
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
