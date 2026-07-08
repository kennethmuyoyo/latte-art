import SwiftUI

/// Hi-Fi "Follow the Guide" — a frosted card of coaching reminders over the
/// camera, with a "Begin" button that starts the pour.
struct BeforePracticeView: View {
    @EnvironmentObject private var flow: AppFlowModel

    private struct Row { let icon: String; let text: String }
    private let rows: [Row] = [
        Row(icon: "circle.circle", text: "Keep your pitcher aligned with the AR path"),
        Row(icon: "cup.and.saucer", text: "Pour steadily"),
        Row(icon: "arrow.trianglehead.2.clockwise", text: "Watch the arrows"),
        Row(icon: "cup.and.heat.waves", text: "Trust the rhythm"),
    ]

    var body: some View {
        ZStack {
            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Follow the Guide")
                        .appText(.headlineBold).foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(rows, id: \.text) { r in
                            IconTextRow(systemIcon: r.icon, text: r.text)
                        }
                    }
                    PillButton(title: "Begin") { flow.beginPractice() }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
            .frame(width: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            BackButton { flow.back() }.padding(16)
        }
    }
}
