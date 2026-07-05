import Foundation
import SwiftUI
import simd
import QuartzCore

/// Owns the simulation, level model, and current pour source, and advances one
/// step per display frame. SwiftUI observes it for fill level and phase-derived
/// UI. Perception (Vision) and touch both feed it through the same `PourSource`.
final class SimulationController: ObservableObject {
    enum Mode { case fill, foam, idle }

    let ctx: MetalContext
    let sim: FluidSimulation
    let level = LevelModel()

    /// Published for the UI.
    @Published var fillLevel: Float = 0
    @Published var mode: Mode = .fill
    @Published var isReadyForFoam = false

    /// Current cup pose (from detection, tap, or centered default in the
    /// Simulator). Published so the SwiftUI guidance overlay tracks it.
    @Published var cupPose: CupPose = .centeredDefault {
        didSet { if cupPose.confidence > 0 { isCupAcquired = true } }
    }

    /// True once a real cup has been acquired (Vision-detected or tapped). On a
    /// camera-driven device, the fluid and pour input are gated on this.
    private(set) var isCupAcquired = false

    /// Toggle for the on-screen dot/calibration overlay (ARKit path).
    @Published var showTrackingDebug = true

    // Calibration for the ARKit tap-registration path (see ARFluidView).
    @Published var surfaceDrop: Float = 0.01      // meters below the rim to the water surface
    @Published var radiusScale: Float = 0.95      // disc radius vs the tapped rim circle
    @Published var surfaceFillRise: Float = 0.03  // extra rise as the cup fills

    /// The 3 registration points the user has tapped so far, in view points
    /// (drawn by the overlay). Cleared on reset; 3 → registered.
    @Published var tappedPoints: [CGPoint] = []
    /// True once all 3 rim points are tapped and the cup circle is anchored.
    @Published var cupRegistered = false

    /// Clear the tapped points so the user can re-register the cup.
    func resetCupRegistration() {
        cupRegistered = false
        tappedPoints = []
        cupPose = CupPose(center: cupPose.center, axes: cupPose.axes, angle: cupPose.angle, confidence: 0)
    }

    /// Whether a camera is driving the cup (device). When true, nothing pours
    /// until a cup is acquired; in the Simulator this stays false.
    var isCameraDriven = false

    /// Per-frame hook: `(dt, freshPourOrNil)`. The flow model uses it to drive
    /// the pattern guide in lockstep with the simulation.
    var onAdvance: ((Float, PourSample?) -> Void)?

    private var pourSource: PourSource?
    private var latestPour: PourSample?
    private var lastFrameTime: TimeInterval?

    init(ctx: MetalContext) {
        self.ctx = ctx
        self.sim = FluidSimulation(ctx: ctx)
    }

    func use(pourSource: PourSource) {
        self.pourSource?.stop()
        pourSource.onSample = { [weak self] sample in self?.ingestPour(sample) }
        pourSource.start()
        self.pourSource = pourSource
    }

    /// Accept a pour sample from any source (touch on main, Vision on the camera
    /// queue). Marshals to the main thread where `advance()` reads it.
    func ingestPour(_ sample: PourSample) {
        if Thread.isMainThread {
            latestPour = sample
        } else {
            DispatchQueue.main.async { [weak self] in self?.latestPour = sample }
        }
    }

    func reset() {
        sim.reset()
        level.reset()
        fillLevel = 0
        isReadyForFoam = false
        mode = .fill
        latestPour = nil
    }

    /// Update the pose from continuous cup tracking (device). Keeps the cup
    /// acquired and skips no-op updates so we don't publish 60x/sec while the
    /// cup is still. Ignored before acquisition or in the Simulator.
    func updateTrackedPose(_ pose: CupPose) {
        guard isCupAcquired else { return }
        if cupPose.approxEquals(pose) { return }
        cupPose = pose
    }

    /// Forget the acquired cup so it must be re-acquired (used on restart). No
    /// effect in the Simulator, which uses a virtual cup.
    func releaseCup() {
        guard isCameraDriven else { return }
        isCupAcquired = false
        cupPose = CupPose(center: cupPose.center, axes: cupPose.axes, angle: cupPose.angle, confidence: 0)
    }

    /// Advance one frame. Called by the MTKView delegate.
    func advance() {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - (lastFrameTime ?? now), 1.0 / 120.0), 1.0 / 30.0))
        lastFrameTime = now

        // Nothing pours until a cup is acquired (device); Simulator is never gated.
        let cupReady = !isCameraDriven || isCupAcquired

        // Consume the most recent pour sample if it is fresh (within ~100ms).
        let freshPour: PourSample? = (cupReady && latestPour.map { now - $0.time < 0.1 } == true) ? latestPour : nil
        if let pour = freshPour {
            switch mode {
            case .fill:
                sim.apply(pour: pour, layingMilk: false)
                level.ingest(pour, dt: dt)
            case .foam:
                sim.apply(pour: pour, layingMilk: true)
            case .idle:
                break
            }
        } else {
            level.idle(dt: dt)
        }

        sim.step(dt: dt, fillLevel: level.fillLevel)
        onAdvance?(dt, freshPour)

        // Publish on the main thread (we are on the render loop / main thread).
        if fillLevel != level.fillLevel { fillLevel = level.fillLevel }
        let ready = level.isFull
        if ready != isReadyForFoam { isReadyForFoam = ready }
    }
}
