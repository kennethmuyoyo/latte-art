import SwiftUI

/// 3 pattern cards, each with its own Start button — tapping one jumps
/// straight into that pattern's pre-practice guide (confirmed against the
/// design mockup over the alternate "select then single Start Practice
/// button" wording in the copy doc).
struct PatternSelectView: View {
    @ObservedObject var model: AppFlowModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()

            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text("Choose Your Next Pattern")
                        .font(.title2.bold())
                    Text("Master the fundamentals, one pour at a time.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.top, 20)

                HStack(spacing: 14) {
                    ForEach(LattePattern.allCases) { pattern in
                        PatternCard(pattern: pattern) {
                            model.choose(pattern)
                        }
                    }
                }
                .padding(.horizontal, 40)

                Spacer()
            }
            .foregroundStyle(.white)
        }
    }
}

private struct PatternCard: View {
    let pattern: LattePattern
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(pattern.thumbnailAssetName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(pattern.displayName)
                .font(.headline)

            Text(pattern.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onStart) {
                Text("Start")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
