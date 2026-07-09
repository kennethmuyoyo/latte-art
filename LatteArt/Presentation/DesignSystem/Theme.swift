import SwiftUI

// Design tokens transcribed from the Figma "Ballerina Cappucino" UI Kit
// (file iOeDo65DQTFRktey3ZmOu3, "Color" + "Typography" frames). Colors and the
// SF Pro type scale are defined once here so every screen speaks the same
// system. This is Presentation-only; it consumes nothing from Sensor/Simulation.

// MARK: - Color palette

enum Palette {
    /// Feedback colors (UI Kit "For instructions"): iOS system red/green.
    static let wrong = Color(hex: 0xFF3B30) // ❌ off-track
    static let correct = Color(hex: 0x34C759) // ✅ on-track

    /// Warm dark neutrals (UI Kit "Dark Shade").
    static let ink = Color(hex: 0x000000)
    static let warmDark = Color(hex: 0x65635C)
    static let warmGray = Color(hex: 0x93928E)

    /// White shades used for text/overlays over the camera.
    static let onCamera = Color.white
    static let onCameraDim = Color.white.opacity(0.7)
    static let onCameraFaint = Color.white.opacity(0.25)

    /// Scrim behind text-heavy screens so white copy stays legible over any feed.
    static let scrim = Color.black.opacity(0.28)
}

extension Color {
    /// 0xRRGGBB initializer for transcribing Figma hex tokens.
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

// MARK: - Typography

/// The UI Kit type scale (SF Pro; specs list Inter but the shipped specs are all
/// "SF Pro", so we use the system font). Each case carries size / weight /
/// tracking exactly as the "Typography" frame documents.
enum AppTextStyle {
    case title1 // SF Pro Bold 22 / LH 28 / -0.2
    case title2 // SF Pro Bold 20 / LH 25 / -0.7
    case headlineBold // SF Pro Bold 17 / LH 22 / -0.2
    case headline // SF Pro Medium 17 / LH 22 / -0.2
    case bodyBold // SF Pro Bold 15 / LH 20 / -0.2
    case body // SF Pro Medium 15 / LH 20 / -0.2
    case small // SF Pro Medium 13 / LH 18 / -0.2

    var font: Font {
        switch self {
        case .title1: return .system(size: 22, weight: .bold)
        case .title2: return .system(size: 20, weight: .bold)
        case .headlineBold: return .system(size: 17, weight: .bold)
        case .headline: return .system(size: 17, weight: .medium)
        case .bodyBold: return .system(size: 15, weight: .bold)
        case .body: return .system(size: 15, weight: .medium)
        case .small: return .system(size: 13, weight: .medium)
        }
    }

    var tracking: CGFloat {
        switch self {
        case .title2: return -0.7
        default: return -0.2
        }
    }
}

private struct AppTextModifier: ViewModifier {
    let style: AppTextStyle
    func body(content: Content) -> some View {
        content.font(style.font).tracking(style.tracking)
    }
}

extension View {
    /// Apply a UI Kit text style (font + tracking).
    func appText(_ style: AppTextStyle) -> some View {
        modifier(AppTextModifier(style: style))
    }
}

// MARK: - Layout constants

enum Metrics {
    static let screenPadding: CGFloat = 28
    static let cardCorner: CGFloat = 22
    static let pillCorner: CGFloat = 25
    static let cardSpacing: CGFloat = 14
}
