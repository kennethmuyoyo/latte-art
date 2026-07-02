import SwiftUI
import simd

/// CoreGraphics/SwiftUI guidance layer drawn over the fluid: cup rim, fill ring,
/// and (during FormArt) the pattern target + direction + status (spec §7,§8).
struct GuidanceOverlay: View {
    let pose: CupPose
    let fillLevel: Float
    let showFillRing: Bool
    var guide: PatternGuide?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // Cup rim outline.
                CupShapes.rimPath(pose: pose, in: size)
                    .stroke(.white.opacity(0.5), lineWidth: 2)

                // Fill-level ring (Focus B, visualized).
                if showFillRing {
                    CupShapes.rimPath(pose: pose, in: size)
                        .trim(from: 0, to: CGFloat(min(max(fillLevel, 0), 1)))
                        .stroke(fillColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                }

                // Live pattern guidance (observes the guide for per-frame updates).
                if let guide {
                    PatternGuidanceLayer(pose: pose, guide: guide, size: size)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var fillColor: Color {
        fillLevel >= 0.98 ? .red : (fillLevel >= 0.85 ? .green : .orange)
    }
}

/// Observes the `PatternGuide` so the target ring, arrow, and ✅/❌ update every
/// frame as the choreography advances and the pour is evaluated.
private struct PatternGuidanceLayer: View {
    let pose: CupPose
    @ObservedObject var guide: PatternGuide
    let size: CGSize

    var body: some View {
        ZStack {
            if let target = guide.liveTargetUV, let step = guide.currentStep {
                let p = CupShapes.viewPoint(target, pose: pose, in: size)

                if simd_length(step.direction) > 0 {
                    CupShapes.arrow(from: p, dir: step.direction)
                        .stroke(.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                }

                Circle()
                    .stroke(guide.onTrack ? Color.green : Color.red, lineWidth: 4)
                    .frame(width: 54, height: 54)
                    .position(x: p.x, y: p.y)

                Image(systemName: guide.onTrack ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(guide.onTrack ? .green : .red)
                    .position(x: p.x + 40, y: p.y - 40)
            }
        }
    }
}

/// Geometry helpers shared by the overlay layers.
enum CupShapes {
    static func viewPoint(_ uv: SIMD2<Float>, pose: CupPose, in size: CGSize) -> CGPoint {
        let v = pose.viewPoint(fromCupUV: uv)
        return CGPoint(x: CGFloat(v.x) * size.width, y: CGFloat(v.y) * size.height)
    }

    static func rimPath(pose: CupPose, in size: CGSize) -> Path {
        var path = Path()
        let n = 72
        for i in 0...n {
            let a = Float(i) / Float(n) * 2 * .pi
            // Start at top (-90°) so the fill trim grows from the top clockwise.
            let ang = a - .pi / 2
            let uv = CupSpace.center + SIMD2<Float>(cos(ang), sin(ang)) * CupSpace.radius
            let p = viewPoint(uv, pose: pose, in: size)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    static func arrow(from start: CGPoint, dir: SIMD2<Float>) -> Path {
        let d = simd_normalize(dir)
        let len: CGFloat = 60
        let end = CGPoint(x: start.x + CGFloat(d.x) * len, y: start.y + CGFloat(d.y) * len)
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        let perp = CGPoint(x: CGFloat(-d.y), y: CGFloat(d.x))
        let back = CGPoint(x: end.x - CGFloat(d.x) * 14, y: end.y - CGFloat(d.y) * 14)
        path.move(to: end)
        path.addLine(to: CGPoint(x: back.x + perp.x * 9, y: back.y + perp.y * 9))
        path.move(to: end)
        path.addLine(to: CGPoint(x: back.x - perp.x * 9, y: back.y - perp.y * 9))
        return path
    }
}
