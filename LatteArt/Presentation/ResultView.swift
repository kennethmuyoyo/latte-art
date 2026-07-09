import Photos
import SwiftUI

/// Minimal completion screen shown once a pattern's choreography genuinely
/// finishes (`PatternGuide.finished`, which now only happens after real
/// sustained on-track pouring — see `PatternGuide.advance`). The finished
/// pour stays visible behind a small card offering another attempt or a new
/// pattern, plus a photo of the art (camera + painted surface, captured the
/// moment this screen appears) the user can save to Photos or share.
struct ResultView: View {
    @ObservedObject var model: AppFlowModel

    /// Composited scene photo — captured once in `onAppear`, before the sim
    /// has time to keep diffusing the pattern away underneath this screen.
    @State private var art: UIImage?
    @State private var saveState: SaveState = .idle

    private enum SaveState { case idle, saving, saved, failed }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            GlassCard {
                VStack(spacing: 18) {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(Palette.correct)
                        Text("Nice work!")
                            .appText(.title2).foregroundStyle(.white)
                        if let pattern = model.selectedPattern {
                            Text("You finished the \(pattern.displayName).")
                                .appText(.body).foregroundStyle(Palette.onCameraDim)
                                .multilineTextAlignment(.center)
                        }
                    }

                    if let art {
                        Image(uiImage: art)
                            .resizable()
                            .scaledToFill()
                            // Explicit width AND height: `scaledToFill` with
                            // only a height overflows its layout frame and
                            // crowds the rows around it.
                            .frame(width: 300, height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Palette.onCameraFaint, lineWidth: 0.5)
                            )

                        HStack(spacing: 14) {
                            actionChip(title: saveLabel, icon: saveIcon,
                                       disabled: saveState == .saving || saveState == .saved) {
                                save(art)
                            }
                            actionChip(title: "Share", icon: "square.and.arrow.up") {
                                share(art)
                            }
                        }
                    }

                    HStack(spacing: 14) {
                        PillButton(title: "New Pattern", prominent: false) { model.backToPatterns() }
                        PillButton(title: "Try Again") { model.tryAgain() }
                    }
                }
            }
            .frame(width: 380)
        }
        .onAppear {
            model.coordinator?.captureArtPhoto { art = $0 }
        }
    }

    /// Save/Share as real, visually separated capsules with full-size tap
    /// targets — bare `Label`s sat flush against each other and were easy to
    /// mis-hit.
    private func actionChip(title: String, icon: String, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .appText(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(Palette.onCameraFaint, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1)
    }

    private var saveLabel: String {
        switch saveState {
        case .idle: return "Save Photo"
        case .saving: return "Saving…"
        case .saved: return "Saved"
        case .failed: return "Retry Save"
        }
    }

    private var saveIcon: String {
        saveState == .saved ? "checkmark" : "square.and.arrow.down"
    }

    /// Standard share sheet, presented from the topmost view controller of
    /// the ACTIVE scene's key window. Deliberately UIKit rather than
    /// `ShareLink` (which silently did nothing in this AR-backed window).
    /// Getting the presenting VC right matters beyond the sheet itself: a
    /// presentation that lands on the wrong window sits invisibly over the
    /// UI and swallows every subsequent tap — which reads as unrelated
    /// buttons ("New Pattern") mysteriously not working.
    private func share(_ image: UIImage) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let window = scene?.keyWindow ?? scene?.windows.first,
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        // iPhone-only app, but anchor defensively so a future iPad build
        // doesn't crash on the popover requirement.
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(
            x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
        top.present(sheet, animated: true)
    }

    /// Add-only Photos write — `performChanges` raises the add-only permission
    /// prompt itself on first use (NSPhotoLibraryAddUsageDescription).
    private func save(_ image: UIImage) {
        saveState = .saving
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }) { success, _ in
            DispatchQueue.main.async { saveState = success ? .saved : .failed }
        }
    }
}
