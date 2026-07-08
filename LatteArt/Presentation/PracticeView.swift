import SwiftUI
import simd

/// The main coached screen: live AR + fluid render (unchanged composited
/// disc), a coaching chip, a back button, and a directional arrow pointing
/// from the live pour landing point toward the current step's target.
///
/// Coaching chip styling note: the mockup uses the SAME dark translucent pill
/// for both on-track and off-track feedback — the only visual difference is a
/// red ❌ icon appearing before the text when `guide.isError` is true. It is
/// NOT a green-background/red-background color-coded chip.
struct PracticeView: View {
    @ObservedObject var model: AppFlowModel
    @ObservedObject var coordinator: CameraPourCoordinator
    @ObservedObject var guide: PatternGuide

    var body: some View {
        ZStack {
            guidanceArrow
                .allowsHitTesting(false)

            VStack {
                HStack {
                    backButton
                    Spacer()
                }
                coachingChip
                    .padding(.top, 8)
                Spacer()
            }
            .padding()
        }
    }

    private var backButton: some View {
        Button {
            model.exitPractice()
        } label: {
            Image(systemName: "chevron.left")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.45), in: Circle())
        }
    }

    private var coachingChip: some View {
        HStack(spacing: 6) {
            if guide.isError {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            Text(guide.message)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.6), in: Capsule())
    }

    /// A green arrow from the live pour landing point toward the current
    /// step's target, both mapped from cup UV to screen pixels via the same
    /// projected-ellipse geometry `cupRing` already carries — no separate
    /// projection math needed.
    @ViewBuilder private var guidanceArrow: some View {
        if let ring = coordinator.cupRing, let step = guide.currentStep {
            let from = Self.screenPoint(forCupUV: guide.lastUV ?? CupSpace.center, ring: ring)
            let to = Self.screenPoint(forCupUV: step.targetUV, ring: ring)
            Canvas { context, _ in
                guard simd_distance(SIMD2(Float(from.x), Float(from.y)),
                                    SIMD2(Float(to.x), Float(to.y))) > 4 else { return }
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                context.stroke(path, with: .color(.green), lineWidth: 4)

                let angle = atan2(to.y - from.y, to.x - from.x)
                let headLength: CGFloat = 16
                let headAngle: CGFloat = .pi / 7
                let left = CGPoint(x: to.x - headLength * cos(angle - headAngle),
                                   y: to.y - headLength * sin(angle - headAngle))
                let right = CGPoint(x: to.x - headLength * cos(angle + headAngle),
                                    y: to.y - headLength * sin(angle + headAngle))
                var head = Path()
                head.move(to: to)
                head.addLine(to: left)
                head.move(to: to)
                head.addLine(to: right)
                context.stroke(head, with: .color(.green), lineWidth: 4)
            }
        }
    }

    /// Maps a cup-space UV point (center 0.5,0.5, radius 0.5) to a screen
    /// pixel using `cupRing`'s already-projected ellipse — the same linear
    /// map (rotate a UV-space vector scaled by the ellipse's semi-axes) that
    /// makes `CupPose.center/axes/angle` an exact ellipse representation, not
    /// an approximation (see `CameraPourCoordinator.cupPose(from:)`).
    private static func screenPoint(forCupUV uv: SIMD2<Float>, ring: CameraPourCoordinator.CupRing) -> CGPoint {
        let dx = Double((uv.x - CupSpace.center.x) / CupSpace.radius)
        let dy = Double((uv.y - CupSpace.center.y) / CupSpace.radius)
        let ux = dx * ring.semiAxes.width
        let uy = dy * ring.semiAxes.height
        let cosA = cos(ring.angleRadians), sinA = sin(ring.angleRadians)
        let rx = ux * cosA - uy * sinA
        let ry = ux * sinA + uy * cosA
        return CGPoint(x: ring.center.x + rx, y: ring.center.y + ry)
    }
}
