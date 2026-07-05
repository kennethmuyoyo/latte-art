import Foundation
import simd
import QuartzCore

/// Pour source driven by the pitcher's 2 AprilTags (spout + back). Replaces
/// touch-drag on the ARKit device path entirely: as the real pitcher moves and
/// tilts over the real cup, this produces the same `PourSample` stream
/// `TouchPourSource` produces for the Simulator, so the rest of the app is
/// unaffected.
final class AprilTagPourSource: PourSource {
    private(set) var current: PourSample?
    var onSample: ((PourSample) -> Void)?

    /// Height above the cup's rim plane (meters) below which the pour is
    /// considered "drawing" (foam, layingMilk=true) rather than "mixing"
    /// (plunging from height, layingMilk=false). Tune on device.
    var layingMilkHeightThresholdMeters: Float = 0.045
    /// Tilt angle (radians, from horizontal) mapped to flowRate 0...1.
    var restAngle: Float = 0.15
    var maxAngle: Float = 1.1
    /// Grace period before a momentary tag occlusion (e.g. a hand passing in
    /// front for one frame) ends the pour outright — mirrors the ~100ms
    /// freshness gate `SimulationController.advance()` already applies to any
    /// `PourSource`, so a pour doesn't visibly stutter on a single bad frame.
    private let graceSeconds: TimeInterval = 0.15

    private var lastGoodSampleTime: TimeInterval = 0
    private var active = false

    func start() { active = true }
    func stop() { active = false; current = nil }

    /// Called every ARFrame with this frame's pitcher tag world points (may be
    /// missing one or both) and the current cup geometry (nil until the cup is
    /// acquired).
    func update(pitcherWorldPoints: [Int: SIMD3<Float>], cup: CupGeometry?, time: TimeInterval) {
        guard active, let cup else { end(at: time); return }
        guard let spout = pitcherWorldPoints[AprilTagRoles.pitcherSpoutID],
              let back = pitcherWorldPoints[AprilTagRoles.pitcherBackID] else {
            end(at: time); return
        }

        // Tilt is the angle of the spout->back vector from horizontal: for a
        // rigid pitcher the raw 3D distance between the two tags stays ~fixed
        // regardless of tilt, but this angle changes exactly as the pitcher
        // tips over to pour.
        let d = spout - back
        let horiz = simd_length(SIMD2<Float>(d.x, d.z))
        let tilt = atan2(abs(d.y), max(horiz, 1e-4))

        let uv = CupSpace.clampToCup(cup.cupUV(of: spout))
        // Real 3D translation is already available from tag pose estimation,
        // so pour height is this direct plane-relative distance rather than
        // the pixel-size-vs-camera proxy a depth-less system would need.
        let height = cup.heightAbovePlane(spout)
        let laying = height <= layingMilkHeightThresholdMeters

        let flow = min(1, max(0, (tilt - restAngle) / max(maxAngle - restAngle, 1e-4)))

        var velocity = SIMD2<Float>(0, 0)
        if let prev = current {
            let dt = Float(max(time - prev.time, 1.0 / 120.0))
            velocity = (uv - prev.uv) / dt
        }

        var sample = PourSample(uv: uv, velocity: velocity, flowRate: flow, confidence: 1, time: time)
        sample.layingMilk = laying
        current = sample
        lastGoodSampleTime = time
        onSample?(sample)
    }

    private func end(at time: TimeInterval) {
        guard time - lastGoodSampleTime > graceSeconds else { return }
        current = nil
    }
}
