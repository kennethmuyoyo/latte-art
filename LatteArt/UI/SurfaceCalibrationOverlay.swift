import SwiftUI

/// Post-registration surface tuning (ARKit path): where the disc sits below the
/// rim, its radius, and how far it rises when filling. Tap "hide" to dismiss.
struct SurfaceCalibrationOverlay: View {
    @ObservedObject var controller: SimulationController
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Calibrate surface", systemImage: "slider.horizontal.3")
                    .font(.caption.bold())
                Spacer()
                Button("hide", action: onHide).font(.caption2)
            }
            slider("Surf drop", $controller.surfaceDrop, -0.03, 0.06)
            slider("Radius ×", $controller.radiusScale, 0.6, 1.2)
            slider("Fill rise", $controller.surfaceFillRise, 0.0, 0.08)
        }
        .padding(10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .frame(maxWidth: 320)
    }

    private func slider(_ label: String, _ value: Binding<Float>, _ lo: Float, _ hi: Float) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption2.monospaced()).frame(width: 70, alignment: .leading)
            Slider(value: value, in: lo...hi)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.caption2.monospaced()).frame(width: 46, alignment: .trailing)
        }
    }
}
