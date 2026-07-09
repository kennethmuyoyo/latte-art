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
        ZStack {
            // On-cup guidance (target dot / stroke line), full-bleed and
            // UNPADDED — it draws in the same viewport coordinate space the
            // tracked `cupRing` is reported in, so any padding here would
            // shift the markers off the real cup.
            PourGuideOverlay(coordinator: coordinator, guide: guide)
                .allowsHitTesting(false)

            VStack {
                // Deliberately COMPACT: the full technique paragraph already
                // lives on the Pre-Guide screen — during the pour a slim
                // one-line pill is all the coaching that should sit over the
                // scene (the previous 320pt card covered too much of it).
                StepGuideCard(guide: guide, tone: tone)
                    .padding(.top, 8)
                Spacer()
                if showDebugHUD {
                    PourDebugHUD(coordinator: coordinator)
                        .allowsHitTesting(false)
                }
            }
            .padding()
        }
        // Without an explicit full-screen frame here, the content sizes
        // itself to fit — so toggling the (sizable) debug HUD on/off changed
        // how big it wanted to be, and since the back/debug buttons are
        // anchored to ITS corners via `.overlay(alignment:)`, they visibly
        // moved inward whenever the HUD was hidden. Forcing this to always
        // fill the available space keeps those corners fixed regardless of
        // what's showing inside.
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

/// On-cup guidance, mapped onto the real tracked cup through `CupRing`'s
/// exact conjugate-diameter map (`center + dx·p + dy·q` — see its doc):
///
/// - `.whiteCircle` step: a small dot at the pour target plus a thin dashed
///   ring showing the SAME tolerance zone the judgment uses.
/// - `.sweep` step: the stroke's dashed line with a start dot and an end
///   chevron; the traversed portion fills in solid as you draw it.
/// - Your live landing point: one small dot.
///
/// Deliberately quiet — thin hairline strokes, small marks, and the only
/// "am I following it?" feedback is the tint (white until a pour is tracked,
/// green while on-track, soft red when off), matching the step card's tone.
private struct PourGuideOverlay: View {
    @ObservedObject var coordinator: CameraPourCoordinator
    @ObservedObject var guide: PatternGuide

    var body: some View {
        Canvas { ctx, _ in
            guard let ring = coordinator.cupRing, let step = guide.currentStep else { return }

            // CupRing.p/q are the screen-space images of ONE CUP RADIUS
            // (0.5 in CupSpace UV) along the cup's two conjugate axes.
            func screen(_ uv: SIMD2<Float>) -> CGPoint {
                let dx = CGFloat((uv.x - 0.5) / 0.5)
                let dy = CGFloat((uv.y - 0.5) / 0.5)
                return CGPoint(
                    x: ring.center.x + dx * CGFloat(ring.p.x) + dy * CGFloat(ring.q.x),
                    y: ring.center.y + dx * CGFloat(ring.p.y) + dy * CGFloat(ring.q.y))
            }
            /// A circle of `radiusUV` around a cup-UV point, mapped through
            /// p/q (so it's the TRUE on-cup ellipse, not a screen circle).
            func uvCircle(at uv: SIMD2<Float>, radiusUV: Float) -> Path {
                let k = CGFloat(radiusUV / 0.5)
                let center = screen(uv)
                let m = CGAffineTransform(a: k * CGFloat(ring.p.x), b: k * CGFloat(ring.p.y),
                                          c: k * CGFloat(ring.q.x), d: k * CGFloat(ring.q.y),
                                          tx: center.x, ty: center.y)
                return Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)).applying(m)
            }
            func dot(_ at: CGPoint, radius: CGFloat, color: Color) {
                let r = CGRect(x: at.x - radius, y: at.y - radius,
                               width: 2 * radius, height: 2 * radius)
                // Dark halo first so the mark stays readable over white foam.
                ctx.fill(Path(ellipseIn: r.insetBy(dx: -1.5, dy: -1.5)),
                         with: .color(.black.opacity(0.35)))
                ctx.fill(Path(ellipseIn: r), with: .color(color))
            }

            let tracking = guide.lastUV != nil
            let tint: Color = !tracking ? .white
                : (guide.isError ? Palette.wrong : Palette.correct)
            let dash = StrokeStyle(lineWidth: 2, dash: [7, 6])

            switch step.goal {
            case .whiteCircle:
                // The pour target + the exact judged tolerance zone.
                ctx.stroke(uvCircle(at: step.targetUV, radiusUV: guide.positionTolerance),
                           with: .color(tint.opacity(0.7)), style: dash)
                dot(screen(step.targetUV), radius: 5, color: tint)

            case .sweep:
                // Deliberately NOTHING preset or drawn for the cut — the
                // reference sim has no line concept, and the guide no longer
                // judges one (see StepGoal.sweep). The cue text carries the
                // technique; only the live landing dot below is shown, plus
                // the card's progress bar as travel accrues.
                break
            }

            // Live landing point — where your pour actually is right now.
            if let uv = guide.lastUV {
                dot(screen(uv), radius: 3.5, color: .white.opacity(0.95))
            }
        }
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
        // One slim pill, not a card — coaching must not cover the scene.
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text("\(min(guide.currentIndex + 1, stepCount))/\(stepCount)")
                    .appText(.small)
                    .foregroundStyle(Palette.onCameraDim)
                Text(guide.message)
                    .appText(.small)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                if guide.holdSeconds > 0 {
                    Text(String(format: "%.1fs", guide.holdSeconds))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Palette.onCameraDim)
                }
                switch tone {
                case .correct: Image(systemName: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(tint)
                case .wrong: Image(systemName: "xmark.circle.fill")
                    .font(.footnote).foregroundStyle(tint)
                case .neutral: EmptyView()
                }
            }

            // Live completion of the current step's goal (white laid /
            // stroke traveled) — real, surface-derived progress.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(Palette.correct)
                        .frame(width: geo.size.width * CGFloat(guide.stepProgress))
                }
            }
            .frame(height: 3)
            .animation(.linear(duration: 0.15), value: guide.stepProgress)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Palette.onCameraFaint, lineWidth: 0.5))
        .frame(maxWidth: 400)
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
