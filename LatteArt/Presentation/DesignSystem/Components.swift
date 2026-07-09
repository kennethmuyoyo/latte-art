import SwiftUI

// Reusable UI pieces distilled from the Figma UI Kit (Components / Cards / Alert)
// and the Hi-Fi frames: frosted glass cards, translucent pill buttons, the dark
// cue/feedback pill, onboarding hints, the pattern card, and the back button.
// Everything is styled to float over the live camera background.

// MARK: - Glass card

/// Frosted translucent rounded container — the Hi-Fi "Choose your pattern" and
/// "Follow the Guide" cards.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                    .strokeBorder(Palette.onCameraFaint, lineWidth: 0.5)
            )
    }
}

// MARK: - Pill button (primary CTA)

/// Translucent capsule button used for "I'm Ready!", "Next", "Start", "Begin",
/// "Done" — the frosted pills in the Hi-Fi.
struct PillButton: View {
    let title: String
    var prominent: Bool = true
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .appText(.headlineBold)
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 13)
                .frame(minWidth: 120)
                .background(
                    Capsule(style: .continuous)
                        .fill(prominent ? AnyShapeStyle(Palette.warmDark.opacity(0.9)) : AnyShapeStyle(.ultraThinMaterial))
                )
                .overlay(Capsule().strokeBorder(Palette.onCameraFaint, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }
}

// MARK: - Cue / feedback pill

/// The dark rounded pill shown top-center during practice. Neutral for movement
/// cues ("Pour steadily"), green for on-track, red for a wrong pour — matching
/// the UI Kit Alert colors.
enum CueTone { case neutral, correct, wrong }

struct CuePill: View {
    let text: String
    var tone: CueTone = .neutral

    private var tint: Color {
        switch tone {
        case .neutral: return .white
        case .correct: return Palette.correct
        case .wrong: return Palette.wrong
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            switch tone {
            case .correct: Image(systemName: "checkmark.circle.fill")
            case .wrong: Image(systemName: "xmark.circle.fill")
            case .neutral: EmptyView()
            }
            Text(text).appText(.bodyBold)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Palette.ink.opacity(0.72), in: Capsule(style: .continuous))
        .overlay(Capsule().strokeBorder(tint.opacity(tone == .neutral ? 0 : 0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

// MARK: - Onboarding hint (white icon + caption over camera)

/// White line-art icon + caption drawn directly on the camera — the Setup
/// onboarding steps ("Find a place with good lighting", etc.).
struct OnboardingHint: View {
    let systemIcon: String
    let caption: String
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: systemIcon)
                .font(.system(size: 64, weight: .light))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
            Text(caption)
                .appText(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
        }
        .frame(maxWidth: 360)
    }
}

// MARK: - Icon + text row ("Follow the Guide" card)

struct IconTextRow: View {
    let systemIcon: String
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemIcon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20)
            Text(text)
                .appText(.body)
                .foregroundStyle(Palette.onCameraDim)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Pattern card (Pattern Selection)

/// A single pattern choice: preview thumbnail + name + one-line blurb + Start.
/// Uses an image asset named `imageName` if present, otherwise a coffee-toned
/// placeholder so it renders before a real photo asset exists for it.
struct PatternCardView: View {
    let title: String
    let blurb: String
    let level: Int
    let imageName: String
    var isSelected: Bool = false
    let onStart: () -> Void

    var body: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                PatternThumb(imageName: imageName)
                    .frame(height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(spacing: 6) {
                    Text(title).appText(.headlineBold).foregroundStyle(.white)
                    Text("Lv \(level)")
                        .appText(.small)
                        .foregroundStyle(Palette.onCameraDim)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Palette.onCameraFaint, in: Capsule())
                }
                Text(blurb)
                    .appText(.small)
                    .foregroundStyle(Palette.onCameraDim)
                    .fixedSize(horizontal: false, vertical: true)

                PillButton(title: "Start", prominent: isSelected, action: onStart)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: 200)
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                .strokeBorder(isSelected ? Palette.correct : .clear, lineWidth: 2)
        )
    }
}

/// Pattern preview image with a graceful placeholder.
struct PatternThumb: View {
    let imageName: String
    var body: some View {
        if let ui = UIImage(named: imageName) {
            Image(uiImage: ui).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(colors: [Color(hex: 0x6F4E37), Color(hex: 0x3B2A20)],
                               startPoint: .top, endPoint: .bottom)
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

// MARK: - Back button

/// Translucent circular back control (top-left of the practice screen).
struct BackButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.backward")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Palette.onCameraFaint, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
