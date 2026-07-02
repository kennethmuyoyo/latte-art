import Foundation
import simd

/// One observation of where and how the user is pouring, in cup-normalized space.
///
/// This is the ONLY thing that carries user pour input into the simulation.
/// It is produced identically by the Vision water tracker and by the touch
/// fallback, so the simulation never knows or cares which one is driving it.
struct PourSample {
    /// Landing point of the pour on the cup surface, in `CupSpace` UV.
    var uv: SIMD2<Float>

    /// Motion of the landing point between frames, UV units per second.
    var velocity: SIMD2<Float>

    /// Relative pour strength in `0...1`. From surface-disturbance intensity and
    /// jug tilt for the water tracker; from drag speed for touch.
    var flowRate: Float

    /// Confidence in this sample, `0...1`. Vision cues fuse into this; touch = 1.
    var confidence: Float

    var time: TimeInterval

    init(uv: SIMD2<Float>,
         velocity: SIMD2<Float> = .zero,
         flowRate: Float = 1,
         confidence: Float = 1,
         time: TimeInterval) {
        self.uv = uv
        self.velocity = velocity
        self.flowRate = flowRate
        self.confidence = confidence
        self.time = time
    }
}
