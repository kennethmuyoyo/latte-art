import Combine
import Foundation
import QuartzCore
import Metal
import simd

/// What the surface is doing right now, for the UI.
enum PourPhase { case idle, mixing, drawing }

/// What the SURFACE is doing this frame, for step-completion judgment in the
/// Presentation layer (`PatternGuide`): how full the cup is (the base-building
/// phase is done when the level says so, not on a timer), and how much white
/// is being laid down right now — `phi * flow` is exactly the quantity
/// `advance()` deposits as dye each frame, so a guide accumulating it tracks
/// the real forming pattern, not wall-clock time.
struct SurfaceState {
    var fillFraction: Float = 0
    /// Float fraction φ of the CURRENT fresh sample (0 = plunging/mixing,
    /// 1 = floating/drawing); 0 when there's no fresh sample.
    var phi: Float = 0
    /// Flow of the current fresh sample, ml/s; 0 when there's no fresh sample.
    var flowMlPerSec: Float = 0
}

/// Per-frame physics readouts for the debug HUD (display-only).
struct SimStats {
    var phi: Float = 0
    var froude: Float = 0
    var flow: Float = 0
    var height: Float = 0
    /// Raw pitcher tilt, degrees — shown even when `flow == 0`, so a debug
    /// HUD can tell "tilted, but not past PourPhysics.thetaStart yet" apart
    /// from "no pour sample at all" (see `hasSample`).
    var tiltDegrees: Float = 0
    /// Where the pour is landing on the cup, in `CupSpace` UV.
    var landingUV: SIMD2<Float> = SIMD2(0.5, 0.5)
    /// Whether a fresh `PourSample` fed this frame's stats at all — `false`
    /// means every other field here is a stale/default zero, not a real
    /// "flow is zero" reading (e.g. spout tag not seen, or spout off-cup).
    var hasSample: Bool = false
}

/// The BRAIN glue: consumes a `PourSource`'s `PourSample` stream, runs
/// `PourPhysics`, integrates `LevelModel`, and queues splats on the
/// `FluidSimulation`. Called once per rendered frame by `FluidBlitter`. It never
/// knows whether input came from AprilTag, touch, or the scripted demo.
final class SimulationController: ObservableObject {
    private let sim: FluidSimulation
    private var physics = PourPhysics()
    private var level = LevelModel()

    // Published HUD readouts, throttled to ~12 Hz (every 5th frame) — display-only.
    @Published private(set) var fillFraction: Float = 0
    @Published private(set) var phase: PourPhase = .idle
    @Published private(set) var stats = SimStats()

    /// The dye texture to display this frame.
    var dyeTexture: MTLTexture { sim.dyeTexture }

    /// Fires once per `advance()` call with `dt`, the fresh sample this
    /// frame acted on (post freshness-gate, `nil` if there wasn't one), and
    /// the surface's state this frame (fill level + live deposit signals —
    /// see `SurfaceState`). For Presentation-layer coaching logic that judges
    /// the live pour against a target pattern's forming surface — the
    /// `@Published` stats above are throttled to ~12 Hz for display and don't
    /// carry the sample itself. Purely additive; doesn't change existing
    /// behavior for anything that doesn't set it.
    var onAdvance: ((Float, PourSample?, SurfaceState) -> Void)?

    // Push-based input. We keep a strong ref to the source and cache its latest
    // sample; `advance` gates on freshness so a stale sample can't keep pouring.
    private var source: PourSource?
    private var latestSample: PourSample?

    private var wantsReset = false
    private var frame = 0

    // ==== Milk stream — port of typescript-fluid-simulator's Latte Scene ====
    // (`FluidScene.setObstacle`, tool = Milk.) Their cup radius is 0.42 of a
    // unit domain; ours is 0.5 of cup UV, so every length/speed scales by
    // 0.5/0.42 ≈ 1.19.
    //
    // DELIBERATE deviation from the reference: no time decay. The reference
    // fades the push to zero over 6 s and narrows the stream over 7 s of
    // cumulative pouring; on device, the early-pour dynamics (full push,
    // full-width stream — the part that visibly parts and carries the
    // surface) are the ones that feel right, and the decay made the cut
    // phase feel dead. The stream now behaves like the FIRST seconds of the
    // reference pour for the entire motion.
    private let milkStartSpeed: Float = 0.95        // uv/s (their 0.8 domain/s)
    private let streamRadius: Float = 0.043         // uv (their 0.036)
    private let streamRingWidth: Float = 0.036      // uv (their 0.03)

    // The tracked inputs (landing point, sweep velocity, stream direction)
    // arrive with per-frame tag noise; injecting them raw made the surface
    // twitch frame-to-frame — no liquid moves like that. Coffee's response
    // is damped and inertial, so the sim's INPUTS are low-pass filtered here
    // with this time constant before any splat is built (the solver itself
    // was fine — the shake was garbage-in). ~0.15s: visibly fluid, still
    // responsive to a deliberate stroke (which lags by only ~this much).
    private let inputSmoothingTau: Float = 0.15
    private var smoothedLanding: SIMD2<Float>?
    private var smoothedVelocity = SIMD2<Float>.zero

    // Ignore samples older than this vs. now. `sample.time` is stamped from
    // ARKit's `ARFrame.timestamp`, compared here against `CACurrentMediaTime()`
    // — the two clocks should agree, but `sample.time` is captured BEFORE
    // AprilTag detection runs (`AprilTagTracker.process` is async image
    // processing, not instant), so the real gap by the time this check runs
    // is that detection latency, not just frame-to-frame delivery jitter.
    // Was 0.15s — measured ~0.215s of real gap on-device even with a healthy,
    // correctly-computed sample (confirmed via the pour debug HUD: tilt/flow
    // were both right, only this gate was rejecting it), which meant every
    // single sample was being discarded as "stale" before ever reaching the
    // sim. Raised with real margin above that measurement.
    private let freshness: TimeInterval = 0.4

    init(sim: FluidSimulation) { self.sim = sim }

    /// Attach a source, wire its callback, keep a strong ref, and start it.
    func attach(source: PourSource) {
        detachSource()
        source.onSample = { [weak self] sample in self?.latestSample = sample }
        self.source = source
        source.start()
    }

    func detachSource() {
        source?.stop()
        source?.onSample = nil
        source = nil
        latestSample = nil
    }

    func requestReset() { wantsReset = true }

    /// One sim tick, called by the blitter each frame with the frame's command
    /// buffer.
    func advance(dt: Float, commandBuffer cb: MTLCommandBuffer) {
        var newPhase: PourPhase = .idle
        var s = SimStats()

        // Freshness gate: only pour on a sample newer than `freshness`.
        let freshSample: PourSample? = latestSample.flatMap { sample in
            CACurrentMediaTime() - sample.time <= freshness ? sample : nil
        }
        if let sample = freshSample {
            let derived = physics.derive(from: sample,
                                         surfaceDepthBelowRim: level.surfaceDepthBelowRimMeters)
            s = SimStats(phi: derived.phi, froude: derived.froude,
                         flow: derived.flowMlPerSec, height: derived.heightMeters,
                         tiltDegrees: (sample.tiltRadians ?? 0) * 180 / .pi,
                         landingUV: sample.uv, hasSample: true)
            newPhase = derived.phi >= 0.5 ? .drawing : .mixing

            // Low-pass the tracked inputs before building any splat — see
            // `inputSmoothingTau`. The stats above deliberately keep the RAW
            // values (the debug HUD should show what the sensor reported).
            let alpha = dt / (inputSmoothingTau + dt)
            let rawLanding = CupSpace.clampToCup(sample.uv)
            let landing = smoothedLanding.map { $0 + alpha * (rawLanding - $0) } ?? rawLanding
            smoothedLanding = landing
            smoothedVelocity += alpha * (sample.velocity - smoothedVelocity)

            if derived.flowMlPerSec > 0 {
                let qn = derived.flowMlPerSec / physics.qMax   // normalized flow 0…1

                // The ported stream model (see the constants block above and
                // `k_milkStream`): white disc + set-velocity ring, constant
                // dynamics for the whole motion (no time decay — see above).
                // `qn` scales the push so real tilt still matters (the
                // reference sim's mouse press is binary; our pour isn't).
                let latteV = milkStartSpeed
                let radius = streamRadius
                let cells = Float(sim.size)
                sim.setStream(MilkStream(
                    center: landing,
                    motionVel: smoothedVelocity * cells,
                    // FIXED, toward the user (+y in cup UV = near rim) — per
                    // the reference, whose jet always points at the viewer
                    // and never follows the cursor. The heart DEPENDS on
                    // this being stable: the blob blooms toward the user,
                    // and a cut moving WITH the jet gets its exit edge
                    // pulled into the point. Aiming this along the measured
                    // pitcher direction (an earlier deviation) made the
                    // bloom wander and the cut fight the jet — no heart.
                    forward: SIMD2<Float>(0, 1),
                    radius: radius,
                    ringWidth: streamRingWidth,
                    latteV: latteV * qn * cells,
                    motionGain: latteV * qn
                ))
                level.add(volumeMl: derived.flowMlPerSec * dt)
            }
        } else {
            // The pour broke (no fresh sample): restart the input filters so
            // the next pour starts from its own first position instead of
            // easing in from wherever the last one ended.
            smoothedLanding = nil
            smoothedVelocity = .zero
        }

        if wantsReset {
            wantsReset = false
            level.reset()
            sim.reset(in: cb)
        }
        sim.step(dt: dt, in: cb)
        onAdvance?(dt, freshSample,
                   SurfaceState(fillFraction: level.fillFraction, phi: s.phi, flowMlPerSec: s.flow))

        // Publish HUD readouts at ~12 Hz, not 60 — they're display-only.
        frame += 1
        if frame % 5 == 0 {
            fillFraction = level.fillFraction
            phase = newPhase
            stats = s
        }
    }
}
