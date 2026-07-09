import Foundation
import CoreGraphics

/// Owns the app's top-level flow state and the one `CameraPourCoordinator`
/// every screen shares — the camera feed is now the background for the
/// whole app (not just the camera-specific screens), so there's exactly one
/// AR session / Metal stack, built once, immediately, off the main thread.
///
/// This used to be created lazily on the Calibration tap (permission
/// requested at point of use). Since the camera feed is now the app's
/// background from the very first screen, it has to start building at
/// launch instead — kicked off on a background queue so Setup's UI still
/// appears instantly rather than blocking on Metal pipeline / AprilTag
/// detector setup (the actual source of the old "app takes a while to
/// start" feeling, compounded by every screen transition previously
/// recreating its own `ARSCNView`/`ARSession` from scratch — now there's
/// only ever one, built here, reused for the app's lifetime).
final class AppFlowModel: ObservableObject {
    @Published var phase: Phase = .splash
    @Published var selectedPattern: LattePattern?
    @Published var guide: PatternGuide?
    @Published private(set) var coordinator: CameraPourCoordinator?

    /// Latest laid-out viewport size, applied to the coordinator as soon as
    /// it exists (it may not yet when the root view first reports a size).
    private var viewportSize: CGSize = .zero

    init() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Same force-unwrap precedent CameraPourView.swift already used:
            // Metal/AR are always available on any ARKit-capable device this
            // app targets, so this doesn't need its own error path.
            guard let context = MetalContext(), let coordinator = CameraPourCoordinator(context: context) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                coordinator.viewportSize = self.viewportSize
                self.coordinator = coordinator
                self.wire(coordinator)
            }
        }
    }

    /// Called by the root view's `GeometryReader` on appear/resize — kept on
    /// the model so it can also be applied the moment the coordinator itself
    /// becomes ready (see `init`), not just on layout changes.
    func updateViewport(_ size: CGSize) {
        viewportSize = size
        coordinator?.viewportSize = size
    }

    /// Called by `SplashView` after its brief logo beat.
    func advanceFromSplash() {
        phase = .setup
    }

    func readyForCalibration() {
        phase = .calibration
    }

    func calibrationConfirmed() {
        phase = .patternSelect
    }

    func choose(_ pattern: LattePattern) {
        selectedPattern = pattern
        phase = .preGuide
    }

    func beginPractice() {
        guard let pattern = selectedPattern else { return }
        guide = PatternGuide(choreography: PatternLibrary.choreography(for: pattern))
        phase = .practice
    }

    /// The Practice screen's own back button — bails out mid-session,
    /// straight back to Pattern Selection. Distinct from the natural
    /// completion path (`finishPractice()` → Result) below.
    func exitPractice() {
        guide = nil
        selectedPattern = nil
        phase = .patternSelect
    }

    /// Reached automatically when `guide.finished` — see `wire(_:)`.
    private func finishPractice() {
        phase = .result
    }

    /// Result screen's "Try Again" — restarts the same pattern.
    func tryAgain() {
        beginPractice()
    }

    /// Result screen's "New Pattern".
    func backToPatterns() {
        guide = nil
        selectedPattern = nil
        phase = .patternSelect
    }

    private func wire(_ coordinator: CameraPourCoordinator) {
        coordinator.controller.onAdvance = { [weak self] dt, pour in
            guard let self, self.phase == .practice, let guide = self.guide else { return }
            guide.advance(dt: dt, pour: pour)
            if guide.finished {
                DispatchQueue.main.async { self.finishPractice() }
            }
        }
    }
}
