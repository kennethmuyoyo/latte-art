import Foundation
import simd

/// Drives one practice session: steps through the chosen pattern's
/// choreography, and judges the live pour against the current step each
/// frame. Consumes `PourSample` only — no ARKit/Metal dependency, matching
/// how Sensor/Simulation stay UI-agnostic (spec.md §8's exact design intent).
///
/// The on-track/off-track thresholds below are a reasonable first pass, not
/// values measured against real pour footage — expect to retune once testing
/// on the physical rig, same category as the tilt/occlusion constants in
/// Sensor/Simulation.
final class PatternGuide: ObservableObject {
    let choreography: PourChoreography

    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var onTrack: Bool = true
    @Published private(set) var isError: Bool = false
    @Published private(set) var message: String
    @Published private(set) var finished: Bool = false
    /// Last live pour landing point, in cup UV — lets the Practice screen draw
    /// a "you are here → next target" arrow without duplicating pour tracking.
    @Published private(set) var lastUV: SIMD2<Float>?

    private var elapsed: TimeInterval = 0
    private var justAdvancedStep = false

    private let positionTolerance: Float = 0.12   // UV distance
    private let velocityTooFast: Float = 1.2      // UV/s
    private let heightTooHighMeters: Float = 0.08
    private let heightTooLowMeters: Float = 0.01

    init(choreography: PourChoreography) {
        self.choreography = choreography
        self.message = choreography.steps.first?.note ?? ""
    }

    var currentStep: PourStep? {
        guard currentIndex < choreography.steps.count else { return nil }
        return choreography.steps[currentIndex]
    }

    /// Judges the live pour against the current step, then advances the
    /// choreography — but only ever counts a step's `duration` toward
    /// completion while the pour is genuinely on-track. This used to be two
    /// separate calls (`tick(dt:)` advancing on elapsed wall-clock time,
    /// `evaluate(_:)` only ever touching the coaching text), which meant the
    /// pattern always finished on a fixed ~4-6s timer regardless of what the
    /// pitcher actually did — the tracked motion was cosmetic, not gating.
    /// Merged into one call so "on track" is the only thing that makes time
    /// count: pour badly and the step simply never completes.
    func advance(dt: Float, pour: PourSample?) {
        guard !finished, let step = currentStep else { return }

        // Give the transition line a beat on screen before real-time
        // coaching starts overwriting it on the very next sample.
        if justAdvancedStep {
            justAdvancedStep = false
            return
        }

        guard let pour else {
            onTrack = false
            isError = false
            return
        }
        lastUV = pour.uv

        let distance = simd_distance(pour.uv, step.targetUV)
        let speed = simd_length(pour.velocity)
        var onTrackNow = distance <= positionTolerance
        var errorNow = false
        var candidate = step.note

        if !onTrackNow {
            errorNow = true
            // Prefer whichever signal is most clearly off, in priority order:
            // height (most direct cause, only available on the AprilTag path),
            // then speed, then generic distance-based fallbacks.
            if let height = pour.heightAboveRimMeters, height > heightTooHighMeters {
                candidate = "Your pitcher is too high"
            } else if let height = pour.heightAboveRimMeters, height < heightTooLowMeters {
                candidate = "Pour closer to the surface"
            } else if speed > velocityTooFast {
                candidate = "Too fast"
            } else if distance > 0.3 {
                candidate = "Follow the guide"
            } else if distance > positionTolerance * 1.5 {
                candidate = "Try a smoother motion"
            } else {
                candidate = "Almost there"
            }
        } else if speed > velocityTooFast {
            // Landing in the right spot but moving too fast is still worth flagging.
            onTrackNow = false
            errorNow = true
            candidate = "Keep a steady pace"
        }

        onTrack = onTrackNow
        isError = errorNow
        message = candidate

        // Off-track time doesn't count toward the step's duration — the user
        // has to actually hold the correct pour, not just wait it out.
        guard onTrackNow else { return }
        elapsed += TimeInterval(dt)
        guard elapsed >= step.duration else { return }

        elapsed = 0
        currentIndex += 1
        guard currentIndex < choreography.steps.count else {
            finished = true
            onTrack = true
            isError = false
            return
        }
        message = "Nice. Get ready for the next motion."
        justAdvancedStep = true
    }
}
