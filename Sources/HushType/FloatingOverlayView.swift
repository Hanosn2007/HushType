import SwiftUI
import AppKit

// MARK: - State

/// Visible state of the floating overlay. The window itself is shown/hidden
/// independently — `.hidden` is here only for clarity, in practice the window
/// is ordered out instead of rendering this case.
enum OverlayState: Equatable {
    case hidden
    case recording(level: Float, provider: String?)  // 0.0–1.0 RMS
    case transcribing(provider: String?)
    case polishing
}

/// Observable model so SwiftUI can react to RMS updates.
///
/// Thread-safety: All mutations of `state` MUST happen on the main thread.
/// AppDelegate enforces this by hopping to main before forwarding RMS
/// callbacks (which fire on the CoreAudio IO thread). Not @MainActor-annotated
/// to keep AppDelegate construction synchronous.
final class OverlayStateModel: ObservableObject {
    @Published var state: OverlayState = .hidden
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

    private let pillShape = RoundedRectangle(
        cornerRadius: FloatingOverlayAppearance.cornerRadius,
        style: .continuous
    )

    var body: some View {
        pill
            .padding(FloatingOverlayAppearance.shadowInsets)
            .fixedSize()
    }

    private var pill: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: labelWidth, alignment: .leading)

            ZStack {
                switch model.state {
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
                case .hidden:
                    EmptyView()
                }
            }
            .frame(width: 40, height: 24)
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
    }

    private var label: String {
        switch model.state {
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
        case .hidden:
            return ""
        }
    }

    private var iconName: String {
        switch model.state {
        case .polishing: return "wand.and.sparkles"
        default:         return "mic.fill"
        }
    }

    private var labelWidth: CGFloat {
        // The panel sizes itself when recording begins and does not resize on
        // the later state swap. Cloud recording reserves provider-label width
        // up front; local recording/transcription keeps the original 80 pt.
        switch model.state {
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
        case .recording:     return 1
        case .transcribing:  return 2
        case .polishing:     return 3
        }
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
