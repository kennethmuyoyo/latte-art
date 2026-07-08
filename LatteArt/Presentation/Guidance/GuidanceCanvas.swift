import SwiftUI
import simd

/// CoreGraphics guidance overlay (SwiftUI `Canvas`) — the green pour arrow +
/// target dot drawn on the cup surface for the current `PourStep`. Positioned via
/// `CupPose.viewPoint(fromCupUV:)` so it registers with the fluid disc and the
/// real cup by construction. This is the README's core Presentation deliverable.
struct GuidanceCanvas: View {
    let pose: CupPose
    let step: PourStep
    var active: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                guard active else { return }
                let t = timeline.date.timeIntervalSinceReferenceDate

                func point(_ uv: SIMD2<Float>) -> CGPoint {
                    let v = pose.viewPoint(fromCupUV: uv)
                    return CGPoint(x: CGFloat(v.x) * size.width, y: CGFloat(v.y) * size.height)
                }

                let dir = simd_length(step.direction) > 1e-4 ? simd_normalize(step.direction) : SIMD2<Float>(0, 1)
                let perp = SIMD2<Float>(-dir.y, dir.x)

                // Wiggle steps sway the aim point side to side.
                var target = step.targetUV
                if step.wiggle { target += perp * Float(sin(t * 6)) * 0.05 }

                let half: Float = 0.12
                let start = point(target - dir * half)
                let end = point(target + dir * half)

                let green = GraphicsContext.Shading.color(Palette.correct)

                // Shaft.
                var shaft = Path()
                shaft.move(to: start)
                if step.wiggle {
                    // A gentle S-curve for the wiggle.
                    let mid = point(target)
                    shaft.addQuadCurve(to: end, control: CGPoint(x: mid.x + 18, y: mid.y))
                } else {
                    shaft.addLine(to: end)
                }
                ctx.stroke(shaft, with: green, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))

                // Arrowhead at the end.
                let angle = atan2(end.y - start.y, end.x - start.x)
                let headLen: CGFloat = 16, spread: CGFloat = .pi / 6
                var head = Path()
                head.move(to: end)
                head.addLine(to: CGPoint(x: end.x - headLen * cos(angle - spread),
                                         y: end.y - headLen * sin(angle - spread)))
                head.move(to: end)
                head.addLine(to: CGPoint(x: end.x - headLen * cos(angle + spread),
                                         y: end.y - headLen * sin(angle + spread)))
                ctx.stroke(head, with: green, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))

                // Target dot.
                let dot = point(target)
                let r: CGFloat = 6
                ctx.fill(Path(ellipseIn: CGRect(x: dot.x - r, y: dot.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(Palette.correct.opacity(0.9)))
            }
        }
    }
}
