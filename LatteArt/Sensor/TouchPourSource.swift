import Foundation
import simd
import QuartzCore

/// Touch-driven pour source (spec fallback). Turns finger drags into the exact
/// same `PourSample` stream the Vision water tracker will produce, so the whole
/// app — sim, level, patterns — is buildable and runnable in the Simulator.
final class TouchPourSource: PourSource {
    private(set) var current: PourSample?
    var onSample: ((PourSample) -> Void)?

    private var lastUV: SIMD2<Float>?
    private var lastTime: TimeInterval?
    private var active = false

    func start() { active = true }
    func stop() { active = false; end() }

    /// Feed a touch location already converted to cup-normalized UV.
    func touchMoved(toUV uv: SIMD2<Float>) {
        guard active else { return }
        let now = CACurrentMediaTime()

        var velocity = SIMD2<Float>(0, 0)
        var flow: Float = 0.35   // resting flow from a stationary touch
        if let lu = lastUV, let lt = lastTime {
            let dt = Float(max(now - lt, 1.0 / 120.0))
            velocity = (uv - lu) / dt
            let speed = simd_length(velocity)
            flow = min(1, 0.35 + speed * 0.5)   // faster drag = stronger pour
        }

        let sample = PourSample(uv: CupSpace.clampToCup(uv),
                                velocity: velocity,
                                flowRate: flow,
                                confidence: 1,
                                time: now)
        current = sample
        lastUV = uv
        lastTime = now
        onSample?(sample)
    }

    func end() {
        current = nil
        lastUV = nil
        lastTime = nil
    }
}
