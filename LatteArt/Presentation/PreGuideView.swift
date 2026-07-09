import SwiftUI

/// The chosen pattern's real pouring technique (`LattePattern.instructions`)
/// over the live camera feed `AppFlowView` renders behind every screen, with
/// a "Begin" button that starts the pour. Reuses the shared `coordinator`
/// (unused in this screen's own content, kept for call-site symmetry with
/// the other camera-backed screens).
struct PreGuideView: View {
    @ObservedObject var model: AppFlowModel
    @ObservedObject var coordinator: CameraPourCoordinator

    var body: some View {
        ZStack {
            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("How to pour the \(model.selectedPattern?.displayName ?? "pattern")")
                        .appText(.headlineBold).foregroundStyle(.white)
                    Text(model.selectedPattern?.instructions ?? "")
                        .appText(.body).foregroundStyle(Palette.onCameraDim)
                        .fixedSize(horizontal: false, vertical: true)
                    PillButton(title: "Begin") { model.beginPractice() }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
            .frame(width: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
