import Foundation
import simd
import QuartzCore

/// A scripted pour source that traces a circular path inside the cup. Used for
/// demos, screenshots, and automated verification without a finger or camera.
/// Conforms to the same `PourSource` interface, so it drives the real pipeline.
final class AutoPourSource: PourSource {
    private(set) var current: PourSample?
    var onSample: ((PourSample) -> Void)?

    /// Radius of the circular path in UV (kept well inside the cup).
    var pathRadius: Float = 0.28
    var angularSpeed: Float = 1.6   // radians/sec

    private var timer: Timer?
    private var startTime: TimeInterval = 0

    func start() {
        startTime = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.emit()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        current = nil
    }

    private func emit() {
        let now = CACurrentMediaTime()
        let a = Float(now - startTime) * angularSpeed
        let uv = CupSpace.center + SIMD2<Float>(cos(a), sin(a)) * pathRadius
        // Tangential velocity for a circular stir.
        let vel = SIMD2<Float>(-sin(a), cos(a)) * angularSpeed * pathRadius
        let sample = PourSample(uv: uv, velocity: vel, flowRate: 0.9, confidence: 1, time: now)
        current = sample
        onSample?(sample)
    }
}
