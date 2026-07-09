import Foundation
import simd

/// One observation of where and how the user is pouring, in cup-normalized space.
///
/// This is the ONLY thing that carries user pour input into the simulation.
/// It is produced identically by AprilTag pitcher tracking and by the touch
/// fallback, so the simulation never knows or cares which one is driving it.
///
/// ## Contract with Simulation
///
/// Sensor's job is to report **measurements**, not physics conclusions — the
/// tilt angle, never "how hard to pour"; the height, never "mixing or
/// drawing". Simulation (`PourPhysics`) owns every physics decision: the
/// tilt→flow curve, the float-vs-sink Froude gate, etc. Concretely:
///
/// - `tiltRadians` / `heightAboveRimMeters` are the raw, physically-measured
///   fields. They are `nil` when the source has no physical measurement to
///   report (touch, the scripted demo) — Simulation must handle `nil` by
///   falling back to its own placeholder, never by treating it as zero.
/// - `flowRate` / `layingMilk` are a **legacy convenience pair** for sources
///   (touch) that only ever had a normalized 0...1 "how hard" signal and a
///   coarse mixing/drawing guess, not real measurements. `AprilTagPourSource`
///   still populates them (derived from the same raw tilt/height) purely for
///   backward compatibility with any consumer not yet reading the raw fields;
///   new Simulation code should prefer `tiltRadians`/`heightAboveRimMeters`
///   and treat these two as deprecated.
struct PourSample {
    /// Landing point of the pour on the cup surface, in `CupSpace` UV.
    var uv: SIMD2<Float>

    /// Motion of the landing point between frames, UV units per second.
    var velocity: SIMD2<Float>

    /// Relative pour strength in `0...1`. From surface-disturbance intensity and
    /// jug tilt for the water tracker; from drag speed for touch.
    ///
    /// Deprecated for AprilTag-driven pours — prefer `tiltRadians` and derive
    /// flow with `PourPhysics.flow(tilt:)`. Kept for sources with no raw tilt
    /// measurement (touch).
    var flowRate: Float

    /// Confidence in this sample, `0...1`. Vision cues fuse into this; touch = 1.
    var confidence: Float

    var time: TimeInterval

    /// Mixing(false)/drawing(true) hint from sources that can derive it
    /// physically (pitcher pour height). `nil` = "no opinion" — the consumer
    /// falls back to its own mode-based default. Touch/scripted sources leave
    /// this `nil`.
    ///
    /// Deprecated for AprilTag-driven pours — prefer `heightAboveRimMeters`,
    /// a continuous measurement; Simulation should own the mixing/drawing
    /// decision (e.g. via the Froude gate), not consume a pre-baked boolean.
    var layingMilk: Bool? = nil

    /// Pitcher tilt, radians from horizontal, measured directly from the
    /// spout↔back AprilTag pair (`atan2` of their vertical vs. horizontal
    /// separation). `nil` when the source has no physical pitcher to measure
    /// (touch, scripted demo). THE raw input to `PourPhysics.flow(tilt:)`.
    var tiltRadians: Float? = nil

    /// Height of the pitcher's spout tag above the cup's rim plane, meters,
    /// measured directly via `CupGeometry.heightAbovePlane(_:)` (true 3D
    /// translation from AprilTag pose estimation — not a pixel-size proxy).
    /// `nil` when the source has no physical pitcher/cup geometry to measure.
    /// Combine with Simulation's own liquid-surface depth to get total pour
    /// height above the *current* surface (the rim plane is a fixed physical
    /// reference; where the surface sits below it is Simulation's concern).
    var heightAboveRimMeters: Float? = nil

    /// The stream's forward direction on the cup surface, unit vector in
    /// `CupSpace` UV: the horizontal direction the pitcher is tipped toward,
    /// measured as reference-tag → spout-tag projected into cup UV (the spout
    /// leads the pitcher body, so milk lands angled this way and carries the
    /// floating pattern forward even when the landing point holds still —
    /// the "circle drifts ahead" phase of a heart). A raw geometric
    /// measurement, per the contract; Simulation decides how much carry it
    /// produces. `nil` when no reference tag is visible (direction
    /// unmeasurable) or for touch/scripted sources.
    var streamDirectionUV: SIMD2<Float>? = nil

    init(uv: SIMD2<Float>,
         velocity: SIMD2<Float> = .zero,
         flowRate: Float = 1,
         confidence: Float = 1,
         layingMilk: Bool? = nil,
         tiltRadians: Float? = nil,
         heightAboveRimMeters: Float? = nil,
         streamDirectionUV: SIMD2<Float>? = nil,
         time: TimeInterval) {
        self.uv = uv
        self.velocity = velocity
        self.flowRate = flowRate
        self.confidence = confidence
        self.layingMilk = layingMilk
        self.tiltRadians = tiltRadians
        self.heightAboveRimMeters = heightAboveRimMeters
        self.streamDirectionUV = streamDirectionUV
        self.time = time
    }
}
