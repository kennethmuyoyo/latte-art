import SwiftUI

/// Phase 2: choose the pattern to practice.
struct PatternSelectView: View {
    @ObservedObject var model: AppFlowModel

    var body: some View {
        VStack(spacing: 24) {
            Text("Choose a Pattern")
                .font(.largeTitle.bold())
                .padding(.top, 40)
            Text("Pick what you want to practice pouring.")
                .foregroundStyle(.secondary)

            Spacer()
            VStack(spacing: 16) {
                ForEach(LattePattern.allCases) { pattern in
                    Button {
                        model.choose(pattern)
                    } label: {
                        HStack(spacing: 18) {
                            Image(systemName: pattern.symbolName)
                                .font(.title)
                                .frame(width: 44)
                            Text(pattern.displayName)
                                .font(.title2.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            Spacer()
        }
        .tint(.orange)
    }
}
