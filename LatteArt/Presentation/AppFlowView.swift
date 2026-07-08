import SwiftUI

/// The real Presentation root. The camera feed is a single, persistent
/// background for the ENTIRE app — one `ARCameraContainer`/`SimulationView`
/// pair, created once here, with only the phase-specific content switching
/// on top of it. Every screen used to build its own camera pair, which made
/// SwiftUI tear down and recreate the underlying `ARSCNView`/`ARSession` on
/// every phase transition (a real, visible restart cost) — this fixes that
/// at the root instead of screen by screen.
struct AppFlowView: View {
    @ObservedObject var model: AppFlowModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let coordinator = model.coordinator {
                    ARCameraContainer(coordinator: coordinator)
                        .ignoresSafeArea()
                    SimulationView(blitter: coordinator.blitter, transparent: true)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                } else {
                    // Coordinator is still building on a background queue
                    // (see AppFlowModel.init) — shown only for the brief
                    // window before the very first frame is ready.
                    Color.black.ignoresSafeArea()
                }

                content
            }
            .onAppear { model.updateViewport(geo.size) }
            .onChange(of: geo.size) { _, newSize in model.updateViewport(newSize) }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .setup:
            SetupView(model: model)
        case .calibration:
            if let coordinator = model.coordinator {
                CalibrationView(model: model, coordinator: coordinator)
            }
        case .patternSelect:
            PatternSelectView(model: model)
        case .preGuide:
            if let coordinator = model.coordinator {
                PreGuideView(model: model, coordinator: coordinator)
            }
        case .practice:
            if let coordinator = model.coordinator, let guide = model.guide {
                PracticeView(model: model, coordinator: coordinator, guide: guide)
            }
        }
    }
}
