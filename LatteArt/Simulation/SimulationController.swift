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

    // Injection scaling (visual tuning, not physics) — carried from the
    // reference PourEngine.
    private let dyePerSecond: Float = 24      // dye must be ~10× stronger than
                                              // intuition — semi-Lagrangian
                                              // advection smears it.
    private let baseRadius: Float = 0.022
    private let flowRadius: Float = 0.035
    // The white circle must GROW BY DISPLACEMENT, not by staining: dye lands
    // only in this tight core under the stream (the stream's true footprint),
    // while the volume source below pushes over a wider area — so the white
    // region expands because its front (and the crema/pattern around it) is
    // physically shoved outward, which is how real latte art behaves. With
    // dye and displacement sharing one radius, staining saturated the full
    // footprint within a few frames and the pour read as white appearing ON
    // TOP of the coffee instead of pushing it aside.
    private let dyeCoreScale: Float = 0.55
    private let displacementRadiusScale: Float = 1.6
    // Momentum comes from the LANDING POINT's sweep motion (the contract-provided
    // `velocity`), never a constant direction — a constant push drags all the
    // milk one way (the "everything drifts up" bug).
    private let sweepMomentum: Float = 70     // cells/s per (uv/s) of sweep
    private let sweepCap: Float = 90          // cells/s
    // Forward carry from the stream itself (heart mechanics): milk lands
    // angled the way the pitcher is tipped (`PourSample.streamDirectionUV`),
    // driving a broad surface JET that flows forward ahead of the landing
    // point — so a pour HELD IN ONE SPOT still carries the growing circle
    // (and the crema around it) forward; the cut back through it then folds
    // the lobes into the heart. Three things make this a jet rather than a
    // nudge, all learned from the first attempt (a small core-radius impulse
    // that produced no visible drift):
    //  - its own WIDE splat (`carryRadiusScale` × footprint), so the current
    //    spans the whole blob, not just the landing pixel;
    //  - centered a footprint AHEAD of the landing point, where a real
    //    impacting stream's surface current is strongest;
    //  - only softly φ-gated (`0.25 + 0.75φ`): even a firm, semi-plunging
    //    pour drives real surface current — a hard φ gate muted the drift
    //    exactly when the user was actually pouring.
    // Direction is the per-frame MEASURED tip direction, not a constant, so
    // this can't reintroduce the "everything drifts one way" bug.
    private let streamCarry: Float = 45       // cells/s injected at full flow
    private let carryRadiusScale: Float = 2.0
    // Residence time makes holds and strokes DIFFERENT mechanics with one
    // rule: volume deposited per unit area scales with how long the stream
    // sits over a spot. Held pour (speed ≈ 0) → full displacement + forward
    // jet, the blob blooms and drifts (heart step 1). Fast cut stroke →
    // residence collapses, the shove/jet nearly vanish, and what remains is
    // the narrow dye core dragged by `sweepMomentum` — a drawn LINE through
    // the pattern (heart step 2). The speed here is where the crossover
    // sits; the sim never needs to know which guide step is active.
    private let strokeSpeed: Float = 0.35     // uv/s: at this speed, blob-building is halved
    // Volume source strength. Mostly φ-gated (floating foam pushes the surface;
    // plunging milk spreads its volume at depth, so only a thin 0.1 floor
    // survives). Tuning history: 80 with a hard φ gate only pushed near-field
    // (existing patterns unmoved); 220, and 120 with a 0.3 floor, whitewashed
    // the disc under a sustained pour by advecting dye everywhere — but BOTH
    // of those predate (a) velocity damping being fixed at 0.90/frame, which
    // stops the multi-second compounding that caused the whitewash, and
    // (b) the dye core being decoupled above, which removes most of the dye
    // there was to smear. 180 with those in place is the displacement-led
    // look; if whitewash ever reappears under a long pour, step back toward
    // 140 before touching anything else.
    private let displacementScale: Float = 180

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

            if derived.flowMlPerSec > 0 {
                let qn = derived.flowMlPerSec / physics.qMax   // normalized flow 0…1

                // Momentum from the landing point's sweep (contract `velocity`,
                // uv/s), scaled by flow and capped — never a constant direction.
                var momentum = sample.velocity * (sweepMomentum * qn)
                let mag = simd_length(momentum)
                if mag > sweepCap { momentum *= sweepCap / mag }

                // Two splats, two radii, deliberately decoupled (see
                // `dyeCoreScale`): the stain lands only in the stream's tight
                // core (with the impact momentum), while the volume push acts
                // over a wider footprint — the circle then grows because the
                // pour physically displaces the surface outward, not because
                // white was painted across the full radius.
                let footprint = baseRadius + flowRadius * qn
                let landing = CupSpace.clampToCup(sample.uv)
                // Hold vs. stroke — see `strokeSpeed`.
                let residence = 1 / (1 + simd_length(sample.velocity) / strokeSpeed)
                sim.queue(Splat(
                    point: landing,
                    radius: footprint * dyeCoreScale,
                    dye: derived.phi * qn * dyePerSecond * dt,
                    momentum: momentum
                ))
                sim.queue(Splat(
                    point: landing,
                    radius: footprint * displacementRadiusScale,
                    dye: 0,
                    momentum: .zero,
                    displacement: displacementScale * qn * (0.1 + 0.9 * derived.phi) * residence
                ))
                // The stream's forward surface jet — see `streamCarry`.
                if let streamDir = sample.streamDirectionUV {
                    sim.queue(Splat(
                        point: CupSpace.clampToCup(landing + streamDir * footprint),
                        radius: footprint * carryRadiusScale,
                        dye: 0,
                        momentum: streamDir * (streamCarry * qn * (0.25 + 0.75 * derived.phi) * residence)
                    ))
                }
                level.add(volumeMl: derived.flowMlPerSec * dt)
            }
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
