import SwiftUI

/// First screen: a checklist reminder, shown over the live camera feed that
/// `AppFlowView` renders behind every screen — a dark scrim keeps the text
/// legible against whatever the camera happens to be pointed at.
struct SetupView: View {
    @ObservedObject var model: AppFlowModel

    private struct ChecklistItem: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
    }

    private let items = [
        ChecklistItem(icon: "iphone.gen3", text: "Place your phone on the stand"),
        ChecklistItem(icon: "cup.and.saucer.fill", text: "Position the cup inside the guide"),
        ChecklistItem(icon: "drop.fill", text: "Fill up your pitcher with water"),
        ChecklistItem(icon: "lightbulb.fill", text: "Make sure the area is well lit"),
    ]

    @State private var checked: Set<UUID> = []

    private var allChecked: Bool { checked.count == items.count }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()

            HStack(alignment: .center, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Let's Set Up!")
                        .font(.largeTitle.bold())
                    Text("Position your phone, prepare your tools, and fill your pitcher with water")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))

                    if allChecked {
                        Label("All Set!", systemImage: "checkmark.seal.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(.green)
                            .padding(.top, 8)
                    }

                    Spacer()

                    Button {
                        model.readyForCalibration()
                    } label: {
                        Text("I'm Ready!")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(allChecked ? Color.accentColor : Color.gray.opacity(0.4),
                                       in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.white)
                    }
                    .disabled(!allChecked)
                }
                .frame(maxWidth: 320, alignment: .leading)

                VStack(spacing: 12) {
                    ForEach(items) { item in
                        Button {
                            if checked.contains(item.id) { checked.remove(item.id) }
                            else { checked.insert(item.id) }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: item.icon)
                                    .font(.title3)
                                    .frame(width: 28)
                                Text(item.text)
                                    .font(.body)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: checked.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(checked.contains(item.id) ? .green : .white.opacity(0.6))
                                    .font(.title3)
                            }
                            .padding()
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .foregroundStyle(.white)
            .padding(28)
        }
    }
}
