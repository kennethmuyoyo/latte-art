import SwiftUI

/// Top-level view that swaps screens based on the flow phase.
struct AppFlowView: View {
    @StateObject private var model: AppFlowModel

    init(ctx: MetalContext) {
        _model = StateObject(wrappedValue: AppFlowModel(ctx: ctx))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .setup:
                SetupView(model: model)
            case .patternSelect:
                PatternSelectView(model: model)
            case .fillCup, .readyForFoam, .formArt:
                PourView(model: model, controller: model.controller)
            case .result:
                ResultView(model: model)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.3), value: model.phase)
        .onAppear { model.startIfDemo() }
    }
}
