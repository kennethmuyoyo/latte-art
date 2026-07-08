import Combine
import Foundation
import QuartzCore
import Metal
import simd

/// What the surface is doing right now, for the UI.
enum PourPhase { case idle, mixing, drawing }

/// Per-frame physics readouts for the debug HUD (display-only).
struct SimStats {
    var phi: Float = 0
    var froude: Float = 0
    var flow: Float = 0
    var height: Float = 0
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

    /// Fires once per `advance()` call with `dt` and the fresh sample this
    /// frame acted on (post freshness-gate), or `nil` if there wasn't one.
    /// For Presentation-layer coaching logic (matching the live pour against
    /// a target pattern) that needs the raw per-frame sample — the
    /// `@Published` stats above are throttled to ~12 Hz for display and don't
    /// carry the sample itself. Purely additive; doesn't change existing
    /// behavior for anything that doesn't set it.
    var onAdvance: ((Float, PourSample?) -> Void)?

    // Push-based input. We keep a strong ref to the source and cache its latest
    // sample; `advance` gates on freshness so a stale sample can't keep pouring.
    private var source: PourSource?
    private var latestSample: PourSample?

    private var wantsReset = false
    private var frame = 0

    // Injection scaling (visual tuning, not physics) — carried from the
    // reference PourEngine.
    private let dyePerSecond: Float = 28      // dye must be ~10× stronger than
                                              // intuition — semi-Lagrangian
                                              // advection smears it.
    private let baseRadius: Float = 0.022
    private let flowRadius: Float = 0.035
    // Momentum comes from the LANDING POINT's sweep motion (the contract-provided
    // `velocity`), never a constant direction — a constant push drags all the
    // milk one way (the "everything drifts up" bug).
    private let sweepMomentum: Float = 70     // cells/s per (uv/s) of sweep
    private let sweepCap: Float = 90          // cells/s
    // Volume source strength. Mostly φ-gated (floating foam pushes the surface;
    // plunging milk spreads its volume at depth, so only a thin 0.1 floor
    // survives). Tuning history: 80 with a hard φ gate only pushed near-field
    // (existing patterns unmoved); 220, and 120 with a 0.3 floor, whitewashed
    // the disc under a sustained pour by advecting dye everywhere.
    private let displacementScale: Float = 110

    // Ignore samples older than this vs. now (mirrors the Sensor layer's grace).
    private let freshness: TimeInterval = 0.15

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
                         flow: derived.flowMlPerSec, height: derived.heightMeters)
            newPhase = derived.phi >= 0.5 ? .drawing : .mixing

            if derived.flowMlPerSec > 0 {
                let qn = derived.flowMlPerSec / physics.qMax   // normalized flow 0…1

                // Momentum from the landing point's sweep (contract `velocity`,
                // uv/s), scaled by flow and capped — never a constant direction.
                var momentum = sample.velocity * (sweepMomentum * qn)
                let mag = simd_length(momentum)
                if mag > sweepCap { momentum *= sweepCap / mag }

                sim.queue(Splat(
                    point: CupSpace.clampToCup(sample.uv),
                    radius: baseRadius + flowRadius * qn,
                    dye: derived.phi * qn * dyePerSecond * dt,
                    momentum: momentum,
                    displacement: displacementScale * qn * (0.1 + 0.9 * derived.phi)
                ))
                level.add(volumeMl: derived.flowMlPerSec * dt)
            }
        }

        if wantsReset {
            wantsReset = false
            level.reset()
            sim.reset(in: cb)
        }
        sim.step(dt: dt, in: cb)
        onAdvance?(dt, freshSample)

        // Publish HUD readouts at ~12 Hz, not 60 — they're display-only.
        frame += 1
        if frame % 5 == 0 {
            fillFraction = level.fillFraction
            phase = newPhase
            stats = s
        }
    }
}
