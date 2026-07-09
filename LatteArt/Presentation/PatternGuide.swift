import Foundation
import simd

/// Drives one practice session: steps through the chosen pattern's
/// choreography, judging the live pour AND the forming surface against the
/// current step's goal each frame. Consumes `PourSample` + `SurfaceState`
/// only — no ARKit/Metal dependency, matching how Sensor/Simulation stay
/// UI-agnostic.
///
/// Steps complete on surface-derived goals, never timers (see `StepGoal`):
/// a white circle is done when enough floated milk has actually been laid at
/// its spot (the same φ·flow quantity the sim deposits as dye), a stroke is
/// done when the pour has genuinely traversed its path. The previous design
/// accrued wall-clock time while the RAW tracked position sat inside a tight
/// tolerance and the RAW frame-to-frame velocity stayed under a threshold —
/// tag noise (especially spikes in the unsmoothed velocity, each poisoning
/// up to 0.4s of judgments via the controller's sample cache) meant a real,
/// good pour could paint a full pattern while never banking enough on-track
/// time to leave step 1. Judgment now uses the smoothed position, and speed
/// is no longer a gate at all.
///
/// Thresholds are a reasonable first pass, not values measured against real
/// pour footage — expect to retune on the physical rig, same category as the
/// tilt/occlusion constants in Sensor/Simulation.
final class PatternGuide: ObservableObject {
    let choreography: PourChoreography

    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var onTrack: Bool = true
    @Published private(set) var isError: Bool = false
    @Published private(set) var message: String
    @Published private(set) var finished: Bool = false
    /// 0...1 completion of the CURRENT step's goal (white laid / stroke
    /// traversed) — drives the step card's progress bar, so "am I making
    /// progress?" is visible instead of inferred.
    @Published private(set) var stepProgress: Float = 0
    /// Last live pour landing point, in cup UV — EMA-smoothed; the same
    /// smoothed position judgment uses.
    @Published private(set) var lastUV: SIMD2<Float>?

    private var justAdvancedStep = false
    private var smoothedLastUV: SIMD2<Float>?

    // Per-step goal accumulators, reset by `completeStep()`.
    private var whiteLaidMl: Float = 0
    private var sweepFarthest: Float = 0
    private var sweepStarted = false

    /// How far from a white circle's spot still counts as pouring "in one
    /// spot", UV distance. Was 0.12 judged on the RAW position; smoothing
    /// plus this looser bound absorbs real spout-tag noise (reconstructed
    /// positions especially) without letting the pour wander cup-wide.
    private let positionTolerance: Float = 0.18
    /// Below this the pitcher isn't meaningfully pouring at all, ml/s.
    private let minPourFlow: Float = 2
    /// A white circle only accrues while at least this much milk is actually
    /// FLOATING (φ·flow, ml/s) — pouring hard from too high plunges instead
    /// and would stall silently without the coaching this gates.
    private let minDepositRate: Float = 1
    /// A sweep step completes when the stroke has reached this fraction of
    /// its path — the tail end is where the real technique lifts/exits, so
    /// demanding 100% would fail exactly the correct finishing motion.
    private let sweepCompleteAt: Float = 0.85
    /// A sweep must START near the path's beginning (progress ≤ this) — the
    /// stroke is a motion from the circle outward, not a point to land on.
    private let sweepStartZone: Float = 0.35

    init(choreography: PourChoreography) {
        self.choreography = choreography
        self.message = choreography.steps.first?.cue ?? ""
    }

    var currentStep: PourStep? {
        guard currentIndex < choreography.steps.count else { return nil }
        return choreography.steps[currentIndex]
    }

    /// Judge the live pour + surface against the current step's goal; called
    /// once per sim frame (see `SimulationController.onAdvance`).
    func advance(dt: Float, pour: PourSample?, surface: SurfaceState) {
        guard !finished, let step = currentStep else { return }

        // Give the transition line a beat on screen before real-time
        // coaching starts overwriting it on the very next sample.
        if justAdvancedStep {
            justAdvancedStep = false
            return
        }

        guard let pour else {
            // No sample (spout not tracked / off cup): neutral, not an error
            // — accrued progress is kept, judgment resumes with tracking.
            onTrack = false
            isError = false
            smoothedLastUV = nil   // don't ease in from a stale spot when it resumes
            return
        }
        let smoothing: Float = 0.2
        let uv = smoothedLastUV.map { $0 + smoothing * (pour.uv - $0) } ?? pour.uv
        smoothedLastUV = uv
        lastUV = uv

        let pouring = surface.flowMlPerSec >= minPourFlow

        switch step.goal {
        case let .whiteCircle(milkMl, maxHeightMeters):
            judgeWhiteCircle(step: step, uv: uv, pour: pour, surface: surface,
                             goalMl: milkMl, maxHeight: maxHeightMeters, pouring: pouring, dt: dt)
        case let .sweep(lateralTolerance):
            judgeSweep(step: step, uv: uv, tolerance: lateralTolerance, pouring: pouring)
        }
    }

    // MARK: - Goal judgment

    private func judgeWhiteCircle(step: PourStep, uv: SIMD2<Float>, pour: PourSample,
                                  surface: SurfaceState, goalMl: Float, maxHeight: Float,
                                  pouring: Bool, dt: Float) {
        guard pouring else {
            // Hovering without flow: neutral — the cue already says to pour.
            setJudgment(onTrack: false, error: false, message: step.cue)
            return
        }
        let distance = simd_distance(uv, step.targetUV)
        guard distance <= positionTolerance else {
            setJudgment(onTrack: false, error: true,
                        message: distance > 0.3 ? "Bring the stream back to the spot."
                                                : "Hold the stream steady in one spot.")
            return
        }
        if let height = pour.heightAboveRimMeters, height > maxHeight {
            setJudgment(onTrack: false, error: true,
                        message: "Lower the pitcher closer to the surface.")
            return
        }
        // Right spot, right height — white accrues at the rate it's actually
        // floating. φ scales with the real physics, so pouring correctly is
        // the only thing that fills this up.
        let depositRate = surface.phi * surface.flowMlPerSec
        guard depositRate >= minDepositRate else {
            setJudgment(onTrack: false, error: true,
                        message: "Gently — bring the spout right to the surface so the milk floats.")
            return
        }
        setJudgment(onTrack: true, error: false, message: step.cue)
        whiteLaidMl += depositRate * dt
        stepProgress = min(whiteLaidMl / goalMl, 1)
        if whiteLaidMl >= goalMl { completeStep() }
    }

    private func judgeSweep(step: PourStep, uv: SIMD2<Float>, tolerance: Float, pouring: Bool) {
        guard let end = step.targetUVEnd else {
            completeStep()   // malformed data (sweep without a path) — don't trap the user
            return
        }
        guard pouring else {
            setJudgment(onTrack: false, error: false, message: step.cue)
            return
        }
        let start = step.targetUV
        let path = end - start
        let lengthSquared = simd_length_squared(path)
        let progress = lengthSquared > 1e-6
            ? min(max(simd_dot(uv - start, path) / lengthSquared, 0), 1) : 1
        let lateral = simd_distance(uv, start + progress * path)

        guard lateral <= tolerance else {
            setJudgment(onTrack: false, error: true,
                        message: "Keep the stream over the stroke's line.")
            return
        }
        if !sweepStarted {
            guard progress <= sweepStartZone else {
                // Landed on the path but past its start — the stroke has to be
                // drawn from the beginning, not joined partway.
                setJudgment(onTrack: false, error: true,
                            message: "Start the stroke from its beginning.")
                return
            }
            sweepStarted = true
        }
        setJudgment(onTrack: true, error: false, message: step.cue)
        // Ratchet: progress along the path only ever counts forward, so noise
        // can't undo a stroke, and hovering at the end without having drawn
        // it never completes (sweepStarted gates above).
        sweepFarthest = max(sweepFarthest, progress)
        stepProgress = min(sweepFarthest / sweepCompleteAt, 1)
        if sweepFarthest >= sweepCompleteAt { completeStep() }
    }

    // MARK: - State transitions

    private func setJudgment(onTrack: Bool, error: Bool, message: String) {
        self.onTrack = onTrack
        self.isError = error
        self.message = message
    }

    private func completeStep() {
        whiteLaidMl = 0
        sweepFarthest = 0
        sweepStarted = false
        currentIndex += 1
        guard currentIndex < choreography.steps.count else {
            finished = true
            onTrack = true
            isError = false
            stepProgress = 1
            return
        }
        stepProgress = 0
        message = "Nice. Get ready for the next motion."
        justAdvancedStep = true
    }
}
