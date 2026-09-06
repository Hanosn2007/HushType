import SwiftUI
import AppKit

// MARK: - State

/// Visible state of the floating overlay. The window itself is shown/hidden
/// independently — `.hidden` is here only for clarity, in practice the window
/// is ordered out instead of rendering this case.
enum OverlayState: Equatable {
    case hidden
    case connecting
    case connectionFailed
    case connectionDisconnected
    case recording(level: Float, provider: String?)  // 0.0–1.0 RMS
    case transcribing(provider: String?)
    case polishing
    case modelNotice(ModelNoticeKind)
}

/// The short-lived status shown after a local model operation completes.
///
/// The notice has its own overlay window, so this state never replaces an
/// active recording indicator.
enum ModelNoticeKind: Equatable {
    case loaded
    case unloaded
}

/// Observable model so SwiftUI can react to RMS updates.
///
/// Thread-safety: All mutations of `state` MUST happen on the main thread.
/// AppDelegate enforces this by hopping to main before forwarding RMS
/// callbacks (which fire on the CoreAudio IO thread). Not @MainActor-annotated
/// to keep AppDelegate construction synchronous.
final class OverlayStateModel: ObservableObject {
    @Published var state: OverlayState = .hidden

    /// Owned by `FloatingOverlayWindow`. Keeping this in the observed model
    /// lets the right-hand accessory swap without changing the pill geometry.
    @Published var isModelNoticeHovered = false
}

// MARK: - Overlay appearance and host geometry

/// The visual pill and its transparent host must agree about the same shadow.
/// SwiftUI creates a shadow by blurring the source alpha and then translating
/// it. A blur is mathematically unbounded, so a finite NSHostingView keeps
/// three blur radii (the conventional Gaussian 3σ coverage) before applying
/// that translation on every edge.
enum FloatingOverlayAppearance {
    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    static let cornerRadius: CGFloat = 16
    static let shadow = Shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)

    private static let gaussianCoverage: CGFloat = 3

    static var shadowInsets: EdgeInsets {
        let blurOutset = shadow.radius * gaussianCoverage
        return EdgeInsets(
            top: max(0, blurOutset - shadow.y),
            leading: max(0, blurOutset - shadow.x),
            bottom: max(0, blurOutset + shadow.y),
            trailing: max(0, blurOutset + shadow.x)
        )
    }
}

// MARK: - Pill view

struct FloatingOverlayView: View {
    @ObservedObject var model: OverlayStateModel
    let onOpenModels: () -> Void
    let onOpenInputSettings: () -> Void

    private let pillShape = RoundedRectangle(
        cornerRadius: FloatingOverlayAppearance.cornerRadius,
        style: .continuous
    )
    private let contentGap: CGFloat = 12

    var body: some View {
        pill
            .padding(FloatingOverlayAppearance.shadowInsets)
            .fixedSize()
    }

    private var pill: some View {
        HStack(spacing: 0) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                // SF Symbols have different intrinsic widths. Reserve the
                // same slot so model notices keep the listening pill's size.
                .frame(width: 16)

            Color.clear
                .frame(width: contentGap)

            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: labelWidth, alignment: .leading)

            ZStack {
                if case .connecting = model.state {
                    ModernLoadingSpinner()
                        .transition(.opacity)
                }
            }
            // This slot is the actual gap between the text container's right
            // edge and the waveform's left edge. Its center therefore remains
            // correct as the surrounding content changes or localizes.
            .frame(width: contentGap, height: 24)
            .animation(.easeOut(duration: 0.16), value: stateKey)

            ZStack {
                switch model.state {
                case .connecting:
                    AudioBarsView(level: 0)
                case .connectionFailed, .connectionDisconnected:
                    Button(action: onOpenInputSettings) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 40, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.string(
                        "overlay.open_input_settings",
                        fallback: "Open input device settings"
                    )))
                    .help(Text(L10n.string(
                        "overlay.open_input_settings",
                        fallback: "Open input device settings"
                    )))
                case .recording(let level, _):
                    AudioBarsView(level: level)
                        .transition(.opacity)
                case .transcribing:
                    // Pulsing ellipsis — each dot fades in/out independently.
                    // More visually distinct from the 5 bars than a tiny
                    // ProgressView spinner, and the symbol effect handles
                    // the animation reliably inside an NSHostingView.
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.85))
                        .symbolEffect(.pulse.byLayer, options: .repeating)
                        .transition(.opacity)
                case .polishing:
                    ProgressView()
                        .controlSize(.small)
                case .modelNotice(let kind):
                    modelNoticeAccessory(for: kind)
                case .hidden:
                    EmptyView()
                }
            }
            .frame(width: 44, height: 24)
            .animation(.easeInOut(duration: 0.18), value: stateKey)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(VisualEffectBlur(material: .hudWindow))
        .clipShape(pillShape)
        .overlay(
            pillShape
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(
            color: FloatingOverlayAppearance.shadow.color,
            radius: FloatingOverlayAppearance.shadow.radius,
            x: FloatingOverlayAppearance.shadow.x,
            y: FloatingOverlayAppearance.shadow.y
        )
        .accessibilityLabel(Text(label))
    }

    @ViewBuilder
    private func modelNoticeAccessory(for kind: ModelNoticeKind) -> some View {
        if model.isModelNoticeHovered {
            Button(action: onOpenModels) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.string(
                "overlay.open_models",
                fallback: "Open model settings"
            )))
            .help(Text(L10n.string(
                "overlay.open_models",
                fallback: "Open model settings"
            )))
        } else {
            Image(systemName: modelNoticeIconName(for: kind))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.85))
                .accessibilityHidden(true)
        }
    }

    private var label: String {
        switch model.state {
        case .connecting:
            return L10n.string("overlay.listening", fallback: "Listening")
        case .connectionFailed:
            return L10n.string("overlay.connection_failed", fallback: "Connection failed")
        case .connectionDisconnected:
            return L10n.string("overlay.connection_disconnected", fallback: "Disconnected")
        case .recording:
            return L10n.string("overlay.listening", fallback: "Listening")
        case .transcribing(let provider):
            if let provider {
                return L10n.format(
                    "overlay.transcribing_provider",
                    "Transcribing · %1$@",
                    arguments: [provider]
                )
            }
            return L10n.string("overlay.transcribing", fallback: "Transcribing")
        case .polishing:
            return L10n.string("overlay.polishing", fallback: "Polishing…")
        case .modelNotice(.unloaded):
            return L10n.string("overlay.model_unloaded", fallback: "Model unloaded")
        case .modelNotice(.loaded):
            return L10n.string("overlay.model_loaded", fallback: "Model ready")
        case .hidden:
            return ""
        }
    }

    private var iconName: String {
        switch model.state {
        case .connectionFailed, .connectionDisconnected: return "xmark"
        case .polishing: return "wand.and.sparkles"
        case .modelNotice: return "memorychip"
        default:         return "mic.fill"
        }
    }

    private var labelWidth: CGFloat {
        // The panel sizes itself when recording begins and does not resize on
        // the later state swap. Cloud recording reserves provider-label width
        // up front; local recording/transcription keeps the original 80 pt.
        switch model.state {
        case .connecting, .connectionFailed, .connectionDisconnected:
            return 80
        case .recording(_, let provider), .transcribing(let provider):
            return provider == nil ? 80 : 150
        default:
            return 80
        }
    }

    /// Stable key for animating the ZStack content swap (don't animate on
    /// every RMS level change, only on state-class change).
    private var stateKey: Int {
        switch model.state {
        case .hidden:        return 0
        case .connecting:    return 1
        case .connectionFailed: return 2
        case .connectionDisconnected: return 3
        case .recording:     return 4
        case .transcribing:  return 5
        case .polishing:     return 6
        case .modelNotice:   return 7
        }
    }

    private func modelNoticeIconName(for kind: ModelNoticeKind) -> String {
        switch kind {
        case .loaded:   return "checkmark.circle.fill"
        case .unloaded: return "minus.circle"
        }
    }
}

// MARK: - Loading spinner

/// Compact modern activity indicator made from fine, round-ended strokes.
/// It lives in the layout gap rather than being offset by a guessed x value.
private struct ModernLoadingSpinner: View {
    private let spokeCount = 8
    private let revolutionDuration: TimeInterval = 0.8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let progress = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: revolutionDuration) / revolutionDuration

            ZStack {
                ForEach(0..<spokeCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.24 + Double(index) * 0.075))
                        .frame(width: 1.2, height: 3.6)
                        .offset(y: -4.8)
                        .rotationEffect(.degrees(Double(index) * 45))
                }
            }
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(progress * 360))
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

// MARK: - Audio bars (5 vertical capsules driven by RMS)

private struct AudioBarsView: View {
    let level: Float

    private let barCount = 5
    private let maxHeight: CGFloat = 22

    /// Per-bar weight — center bars peak slightly taller for a "voice" curve.
    private let weights: [CGFloat] = [0.55, 0.85, 1.0, 0.85, 0.55]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 3, height: barHeight(index: i))
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
        .frame(height: maxHeight)
    }

    private func barHeight(index: Int) -> CGFloat {
        // Speech RMS is empirically much smaller than I assumed — typical
        // values are 0.005-0.05 for normal voice. Use a square-root mapping
        // with high boost so soft speech reaches mid-range and normal speech
        // saturates the bars.
        let boosted = min(1.0, CGFloat(level) * 30.0)
        let curved = sqrt(boosted)  // sqrt gives more visual range to soft speech
        let scaled = curved * weights[index]
        return max(3, maxHeight * scaled)
    }
}
