import Foundation
import simd

/// Drives the FormArt phase: tracks which choreography step is active, exposes
/// the current target/direction for the guidance overlay, evaluates the live
/// pour as on-track vs missed, and accumulates a score (spec §8).
final class PatternGuide: ObservableObject {
    let choreography: PourChoreography

    @Published private(set) var currentIndex = 0
    @Published private(set) var elapsed: Float = 0
    @Published private(set) var onTrack = true
    @Published private(set) var finished = false

    /// Running accuracy: fraction of evaluated frames the pour was on-track.
    private var trackedFrames = 0
    private var onTrackFrames = 0

    /// Tolerances.
    var positionTolerance: Float = 0.14   // UV distance to target
    var directionTolerance: Float = 0.4   // cosine slack for drag direction

    init(choreography: PourChoreography) {
        self.choreography = choreography
    }

    var currentStep: PourStep? {
        guard currentIndex < choreography.steps.count else { return nil }
        return choreography.steps[currentIndex]
    }

    /// The wiggle-adjusted target the user should be hitting right now.
    var liveTargetUV: SIMD2<Float>? {
        guard let step = currentStep else { return nil }
        guard step.wiggle > 0 else { return step.targetUV }
        // Oscillate horizontally to trace the rosetta leaves.
        let phase = elapsed * 6.0
        return step.targetUV + SIMD2<Float>(sin(phase) * step.wiggle, 0)
    }

    /// Advance time; roll to the next step when the current one elapses.
    func tick(dt: Float) {
        guard !finished, let step = currentStep else { return }
        elapsed += dt
        if elapsed >= step.duration {
            elapsed = 0
            currentIndex += 1
            if currentIndex >= choreography.steps.count { finished = true }
        }
    }

    /// Evaluate a live pour sample against the current expectation.
    func evaluate(_ pour: PourSample?) {
        guard let step = currentStep, let target = liveTargetUV else { return }
        trackedFrames += 1

        guard let pour = pour else {
            onTrack = false   // nothing being poured while a step is active = off
            return
        }

        let posOK = simd_distance(pour.uv, target) <= positionTolerance
        var dirOK = true
        if simd_length(step.direction) > 0, simd_length(pour.velocity) > 0.05 {
            // Drag direction should roughly align with the step's intended direction.
            let cosine = simd_dot(simd_normalize(pour.velocity), step.direction)
            dirOK = cosine >= directionTolerance
        }
        onTrack = posOK && dirOK
        if onTrack { onTrackFrames += 1 }
    }

    /// Final 0–100 score once finished.
    var score: Int {
        guard trackedFrames > 0 else { return 0 }
        return Int((Float(onTrackFrames) / Float(trackedFrames)) * 100)
    }

    func reset() {
        currentIndex = 0
        elapsed = 0
        onTrack = true
        finished = false
        trackedFrames = 0
        onTrackFrames = 0
    }
}
