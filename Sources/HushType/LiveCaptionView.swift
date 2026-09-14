import SwiftUI
import AppKit
import Foundation

/// Semantic role of a dual-line caption row (SPEC §4.5). The visible chip
/// label and the accessibility label are localized renderings of this value;
/// behavior never branches on rendered display text.
enum CaptionLineRole: Equatable, Sendable {
    case source
    case translated

    var label: String {
        switch self {
        case .source: return L10n.string("caption.role.source", fallback: "SOURCE")
        case .translated: return L10n.string("caption.role.translated", fallback: "TRANSLATED")
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .source: return L10n.string("caption.role.source.accessibility", fallback: "Source language")
        case .translated: return L10n.string("caption.role.translated.accessibility", fallback: "Translated")
        }
    }
}

/// Header state — drives the left-side content of the panel header.
enum LiveCaptionHeaderState: Equatable {
    case loadingVAD       // "Loading VAD model…"
    case loadingModel(Double) // local Qwen model load progress, 0...1
    case live              // "● Live"
    case finishing
    case stopped
    case gatedFlash        // "Stop Live Caption to dictate" (orange, 2s)
    case reconnecting(attempt: Int, max: Int)   // cloud transport reconnect
    case autoStopped                            // 5s flash after auto-stop
}

/// The caption panel starts every session in automatic sizing. A native
/// resize opts the current session into manual sizing until the user restores
/// automatic sizing or starts a new session.
enum LiveCaptionSizingMode: Equatable {
    case automatic
    case manual
}

enum LiveCaptionTimestampPreference {
    static let key = "hushtype.liveCaption.showsTimestamps"
}

/// Small value-type state machine kept separate from AppKit so the sizing
/// lifecycle remains testable without creating a window.
struct LiveCaptionSizingState: Equatable {
    private(set) var mode: LiveCaptionSizingMode = .automatic

    var acceptsAutomaticResizing: Bool { mode == .automatic }
    var showsRestoreControl: Bool { mode == .manual }

    @discardableResult
    mutating func userDidResize() -> Bool {
        guard mode != .manual else { return false }
        mode = .manual
        return true
    }

    @discardableResult
    mutating func restoreAutomaticSizing() -> Bool {
        guard mode != .automatic else { return false }
        mode = .automatic
        return true
    }

    mutating func resetForNewSession() {
        mode = .automatic
    }
}

/// SwiftUI body of the live caption panel. Owned/hosted by
/// `LiveCaptionWindow`. State is driven through a small observable model so
/// the manager can `await MainActor.run { … }` from off-actor contexts.
final class LiveCaptionViewModel: ObservableObject {
    @Published var headerState: LiveCaptionHeaderState = .live {
        didSet { invalidateCaptionContentSize() }
    }
    /// Complete in-process session transcript. The manager deliberately does
    /// not trim this array: the view caps its visible height and scrolls.
    @Published var segments: [SegmentEntry] = [] {
        didSet { invalidateCaptionContentSize() }
    }

    /// Small grey line above the target caption — only meaningful for the
    /// cloud translate engine. Nil = hidden. Set/cleared by the manager from
    /// `BackendEvent.sourceDelta` / `.segmentComplete`.
    @Published var currentSourceLine: String? = nil {
        didSet { invalidateCaptionContentSize() }
    }
    /// Main caption font; the in-progress translated line. Nil = hidden.
    @Published var currentTargetLine: String? = nil {
        didSet { invalidateCaptionContentSize() }
    }

    /// "MM:SS · $X.XX" chip shown in the panel header when cloud engine is
    /// active. Nil = hide chip (local engine, or cloud session not yet
    /// emitting audio).
    @Published var cloudCostChip: String? = nil {
        didSet { invalidateCaptionContentSize() }
    }

    /// Waiting translations, excluding the sentence currently being sent to
    /// the local model. The manager updates this from its session queue.
    @Published var translationPendingCount: Int = 0 {
        didSet { invalidateCaptionContentSize() }
    }
    /// Session-level state such as local translation model preparation. An
    /// empty value defers to the compact pending-count status below.
    @Published var translationStatusMessage: String? = nil {
        didSet { invalidateCaptionContentSize() }
    }

    var translationStatusText: String? {
        if let translationStatusMessage,
           !translationStatusMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return translationStatusMessage
        }
        guard translationPendingCount > 0 else { return nil }
        return L10n.format(
            "caption.translation.pending",
            "Translating… %1$d remaining",
            arguments: [Int32(translationPendingCount)]
        )
    }

    /// Rendered by the view to reveal the restore-size control after a native
    /// resize. The window owns transitions; the model only exposes state.
    @Published private(set) var sizingState = LiveCaptionSizingState()
    @Published private(set) var captionSessionGeneration: UInt64 = 0

    /// Installed by `LiveCaptionWindow`. Keeping the layout calculation in
    /// AppKit lets the panel animate its frame while SwiftUI stays declarative.
    var onContentSizeInvalidated: (() -> Void)?

    struct SegmentEntry: Identifiable, Equatable {
        let id: UUID = UUID()
        let text: String
        /// Kept with the committed segment so timestamps reflect when the
        /// caption was received, not when the menu option is turned on.
        let timestamp: Date = Date()
        /// Local caption translation arrives after the source segment has
        /// already been committed and displayed.
        var translatedText: String? = nil
        /// Translation failures leave the source text intact and appear as a
        /// small status line below it.
        var translationError: String? = nil

        /// The durable transcript keeps both the recognition result and its
        /// eventual translation, rather than replacing the source text.
        var historyText: String {
            guard let translatedText,
                  !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return text
            }
            return text + "\n" + translatedText
        }

        /// A compact representation for callers that only show one caption
        /// line. The source remains the fallback until a translation arrives.
        var displayText: String {
            guard let translatedText,
                  !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return text
            }
            return translatedText
        }

        var hasTranslatedText: Bool {
            guard let translatedText else { return false }
            return !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func useManualSizing() {
        guard sizingState.userDidResize() else { return }
        invalidateCaptionContentSize()
    }

    func restoreAutomaticSizing() {
        guard sizingState.restoreAutomaticSizing() else { return }
        invalidateCaptionContentSize()
    }

    func resetSizingForNewSession() {
        sizingState.resetForNewSession()
        captionSessionGeneration &+= 1
        invalidateCaptionContentSize()
    }

    /// View-owned layout preferences, such as timestamps, also affect the
    /// auto-fitting panel. The window installs the callback above.
    func captionLayoutDidChange() {
        invalidateCaptionContentSize()
    }

    private func invalidateCaptionContentSize() {
        onContentSizeInvalidated?()
    }
}

struct LiveCaptionView: View {
    @ObservedObject var model: LiveCaptionViewModel
    @Environment(\.displayScale) private var displayScale
    let onStop: () -> Void
    @StateObject private var scrollFollow = LiveCaptionScrollFollowController()
    @AppStorage(LiveCaptionTimestampPreference.key) private var showsTimestamps = false

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        ZStack(alignment: .top) {
            VisualEffectBlur(material: .hudWindow)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            captionBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(LiveCaptionTopBlur.contentClipShape(backingScale: displayScale))

            // This host remains alive from the Listening state onward. It sits
            // outside every SwiftUI clip/compositing group so Core Animation can
            // keep sampling the current content and desktop behind the panel.
            LiveCaptionTopBlur()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            captionHeader
                .frame(maxWidth: .infinity, alignment: .top)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onExitCommand { onStop() }
        .onAppear {
            // Covers a timestamp preference restored before this panel was
            // created, which otherwise would not emit an `onChange` event.
            model.captionLayoutDidChange()
        }
        .onChange(of: model.captionSessionGeneration) { _, _ in
            scrollFollow.resetForNewSession()
        }
        .onChange(of: showsTimestamps) { _, _ in
            model.captionLayoutDidChange()
            scrollFollow.scheduleScrollToBottomAfterLayout()
        }
    }

    private var captionHeader: some View {
        header
                // 6pt inset plus a 20pt control centers the close circle 16pt
                // from the left and top, aligned to the 16pt glass radius.
                .padding(.leading, 6)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            stopButton
            if model.sizingState.showsRestoreControl {
                restoreAutomaticSizeButton
            }
            headerLeft
                .animation(.easeInOut(duration: 0.18), value: model.headerState)
            Spacer()
            if let chip = model.cloudCostChip {
                Text(chip)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.string(
                        "caption.accessibility.session_cost",
                        fallback: "Cloud Live Caption session cost"
                    ))
            }
            moreButton
        }
        .frame(height: 20)
        .lineLimit(1)
    }

    @ViewBuilder
    private var headerLeft: some View {
        switch model.headerState {
        case .finishing:
            Text(L10n.string("overview.finishing", fallback: "Finishing"))
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
        case .stopped:
            Text(L10n.string("settings.captions.status.stopped", fallback: "Stopped"))
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
        case .loadingModel(let progress):
            HStack(spacing: 6) {
                ProgressView(value: max(0, min(1, progress)))
                    .progressViewStyle(.linear)
                    .frame(width: 64)
                Text(L10n.format(
                    "caption.loading_speech_model",
                    "Loading speech model… %1$d%%",
                    arguments: [Int32(Int(max(0, min(1, progress)) * 100))]
                ))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
            }
        case .loadingVAD:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text(L10n.string("caption.loading_vad", fallback: "Loading VAD model…"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
            }
        case .live:
            HStack(spacing: 8) {
                LivePulseDot()
                // Header text reflects which product is running. Cloud
                // sessions translate audio into a target language; local
                // sessions just transcribe — same UI panel, different
                // products with different cost/privacy profiles, so the
                // header label distinguishes them at a glance.
                Text(AppConfig.shared.liveCaptionEngine == .cloudTranslate
                     ? L10n.string("caption.live_translated", fallback: "Live · Translated")
                     : L10n.string("caption.live", fallback: "Live"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
            }
        case .gatedFlash:
            Text(L10n.string(
                "caption.stop_to_dictate",
                fallback: "Stop Live Caption to dictate"
            ))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.orange)
        case .reconnecting(let attempt, let max):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text(L10n.format(
                    "caption.reconnecting",
                    "Reconnecting (%1$d/%2$d)…",
                    arguments: [Int32(attempt), Int32(max)]
                ))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.orange)
            }
        case .autoStopped:
            Text(L10n.string("caption.auto_stopped", fallback: "Auto-stopped"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary.opacity(0.78))
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string(
            "caption.stop.accessibility",
            fallback: "Stop live caption"
        ))
        .help(L10n.string("caption.stop.help", fallback: "Stop live caption (Esc)"))
    }

    private var restoreAutomaticSizeButton: some View {
        Button(action: model.restoreAutomaticSizing) {
            Image(systemName: "arrow.down.right.and.arrow.up.left.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary.opacity(0.78))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string(
            "caption.restore_automatic_size.accessibility",
            fallback: "Restore automatic caption size"
        ))
        .help(L10n.string(
            "caption.restore_automatic_size.help",
            fallback: "Restore automatic size"
        ))
    }

    private var moreButton: some View {
        Menu {
            Toggle(
                L10n.string("caption.timestamps", fallback: "Show timestamps"),
                isOn: $showsTimestamps
            )
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary.opacity(0.78))
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20, height: 20)
        .accessibilityLabel(L10n.string(
            "caption.more.accessibility",
            fallback: "More live caption options"
        ))
        .help(L10n.string("caption.more.help", fallback: "More options"))
    }

    // MARK: - Body

    @ViewBuilder
    private var captionBody: some View {
        if model.segments.isEmpty && !hasCurrentLine && !hasTranslationStatus {
            listeningPlaceholder
        } else {
            VStack(alignment: .leading, spacing: 0) {
                scrollback
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                currentLineRegion
                translationStatusRegion
            }
        }
    }

    private var hasCurrentLine: Bool {
        (model.currentSourceLine != nil) || (model.currentTargetLine != nil)
    }

    private var hasTranslationStatus: Bool {
        model.translationStatusText != nil
    }

    private var listeningPlaceholder: some View {
        HStack {
            Spacer()
            Text(L10n.string("caption.listening", fallback: "Listening…"))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .padding(.top, LiveCaptionTopBlur.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var currentLineRegion: some View {
        if hasCurrentLine {
            dualLineRegion
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var translationStatusRegion: some View {
        if let translationStatus = model.translationStatusText {
            Text(translationStatus)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .lineSpacing(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 2)
                .padding(.bottom, 8)
                .accessibilityLabel(translationStatus)
        }
    }

    /// Full-session history. New rows follow the live edge only while the
    /// reader is already at the bottom, so selecting or scrolling older text
    /// never snaps the reader back to the newest caption.
    private var scrollback: some View {
        GeometryReader { viewport in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.segments) { entry in
                        segmentRow(entry)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, LiveCaptionTopBlur.height + 10)
                .padding(.bottom, 10)
                // A short transcript cannot be scrolled downward: its
                // document is smaller than the viewport. Give it the full
                // viewport height and align the actual rows at the bottom.
                .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .bottomLeading)
                .background(LiveCaptionScrollPositionObserver(controller: scrollFollow))
            }
        }
        .onChange(of: model.segments) { previousSegments, currentSegments in
            if currentSegments.isEmpty, !previousSegments.isEmpty {
                scrollFollow.resetForNewSession()
                return
            }
            // Translation and error rows can make an existing history entry
            // taller. The controller only scrolls while following the live
            // edge, so a reader inspecting older captions keeps their place.
            guard currentSegments != previousSegments else { return }
            scrollFollow.scheduleScrollToBottomAfterLayout()
        }
    }

    @ViewBuilder
    private func segmentRow(_ entry: LiveCaptionViewModel.SegmentEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showsTimestamps {
                Text(Self.timestampFormatter.string(from: entry.timestamp))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .font(.system(size: entry.hasTranslatedText ? 14 : 17, weight: .regular))
                    .lineSpacing(1)
                    .foregroundStyle(entry.hasTranslatedText ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let translatedText = entry.translatedText,
                   !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(translatedText)
                        .font(.system(size: 17, weight: .regular))
                        .lineSpacing(1)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let translationError = entry.translationError,
                   !translationError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(translationError)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Pinned dual-line region below the scrollback: source line on top
    /// (small grey, source chip), translated line below (main caption font,
    /// translated chip). Both share a single left accent rule so the user
    /// reads them as one translation pair rather than two unrelated lines.
    /// Collapses when both are nil.
    private var dualLineRegion: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.55))
                .frame(width: 2)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                if let source = model.currentSourceLine, !source.isEmpty {
                    dualLineRow(
                        role: .source,
                        text: source,
                        fontSize: 12,
                        color: .secondary
                    )
                }
                if let target = model.currentTargetLine, !target.isEmpty {
                    dualLineRow(
                        role: .translated,
                        text: target,
                        fontSize: 17,
                        color: .primary
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One line of the dual-line region. Fixed-width pill chip on the left
    /// (so the role chips stack vertically aligned), then the caption. The
    /// chip is intentionally bold + capsule-shaped so the role is readable at
    /// panel viewing distance. The role is a semantic enum: visible text and
    /// accessibility text are both localized output of it.
    @ViewBuilder
    private func dualLineRow(role: CaptionLineRole, text: String, fontSize: CGFloat, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(role.label)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.5)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.14), in: Capsule())
                .frame(width: 92, alignment: .leading)
                .accessibilityLabel(role.accessibilityLabel)
            Text(text)
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(color)
                .lineSpacing(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

/// Owns one concrete AppKit scroll view. Only the three native live-scroll
/// notifications can turn off live-follow; document/window layout changes and
/// our own `scroll(to:)` calls only keep an already-following reader at the
/// bottom.
final class LiveCaptionScrollFollowController: ObservableObject {
    @Published private(set) var followsLiveEdge = true

    private weak var scrollView: NSScrollView?
    private var notificationObservers: [NSObjectProtocol] = []
    private var scrollAfterLayoutIsScheduled = false
    private var userIsLiveScrolling = false

    deinit {
        stopObserving()
    }

    func attach(to newScrollView: NSScrollView) {
        guard scrollView !== newScrollView else { return }
        stopObserving()
        scrollView = newScrollView

        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: newScrollView,
                queue: .main
            ) { [weak self] _ in
                self?.willStartUserScroll()
            },
            center.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: newScrollView,
                queue: .main
            ) { [weak self] _ in
                self?.updateFollowStateFromUserScroll()
            },
            center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: newScrollView,
                queue: .main
            ) { [weak self] _ in
                self?.endUserScroll()
            },
        ]

        // Window frame interpolation changes this clip frame. Keep a reader
        // who is already following pinned to the bottom without interpreting
        // that resize as a user scroll.
        newScrollView.contentView.postsFrameChangedNotifications = true
        notificationObservers.append(
            center.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: newScrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleScrollToBottomAfterLayout()
            }
        )
        if let documentView = newScrollView.documentView {
            documentView.postsFrameChangedNotifications = true
            notificationObservers.append(
                center.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: documentView,
                    queue: .main
                ) { [weak self] _ in
                    self?.scheduleScrollToBottomAfterLayout()
                }
            )
        }
        scheduleScrollToBottomAfterLayout()
    }

    func resetForNewSession() {
        userIsLiveScrolling = false
        followsLiveEdge = true
        scheduleScrollToBottomAfterLayout()
    }

    /// Coalesces model additions and clip-frame changes until SwiftUI has laid
    /// out the document view, then moves the actual `NSClipView` once.
    func scheduleScrollToBottomAfterLayout() {
        guard followsLiveEdge, !userIsLiveScrolling, !scrollAfterLayoutIsScheduled else { return }
        scrollAfterLayoutIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollAfterLayoutIsScheduled = false
            self.scrollToBottomIfFollowing()
        }
    }

    private func willStartUserScroll() {
        userIsLiveScrolling = true
        scrollAfterLayoutIsScheduled = false
        // Suspend immediately so an arriving segment cannot fight a drag
        // between the system's will-start and did-scroll notifications.
        followsLiveEdge = false
    }

    private func updateFollowStateFromUserScroll() {
        guard userIsLiveScrolling else { return }
        followsLiveEdge = isAtBottom
    }

    private func endUserScroll() {
        guard userIsLiveScrolling else { return }
        followsLiveEdge = isAtBottom
        userIsLiveScrolling = false
    }

    private func scrollToBottomIfFollowing() {
        guard followsLiveEdge,
              !userIsLiveScrolling,
              let scrollView,
              let documentView = scrollView.documentView else { return }

        scrollView.layoutSubtreeIfNeeded()
        documentView.layoutSubtreeIfNeeded()
        let clipView = scrollView.contentView
        let targetY: CGFloat
        if documentView.isFlipped {
            targetY = max(documentView.bounds.minY, documentView.bounds.maxY - clipView.bounds.height)
        } else {
            targetY = documentView.bounds.minY
        }
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
    }

    private var isAtBottom: Bool {
        guard let scrollView, let documentView = scrollView.documentView else { return true }
        let clipBounds = scrollView.contentView.bounds
        if documentView.isFlipped {
            return clipBounds.maxY >= documentView.bounds.maxY - 8
        }
        return clipBounds.minY <= documentView.bounds.minY + 8
    }

    private func stopObserving() {
        let center = NotificationCenter.default
        notificationObservers.forEach(center.removeObserver)
        notificationObservers.removeAll()
        scrollView = nil
        scrollAfterLayoutIsScheduled = false
    }
}

private struct LiveCaptionScrollPositionObserver: NSViewRepresentable {
    let controller: LiveCaptionScrollFollowController

    func makeNSView(context: Context) -> ProbeView {
        ProbeView(controller: controller)
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.controller = controller
        nsView.attachIfPossible()
    }

    final class ProbeView: NSView {
        var controller: LiveCaptionScrollFollowController

        init(controller: LiveCaptionScrollFollowController) {
            self.controller = controller
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unsupported")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfPossible()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attachIfPossible()
        }

        func attachIfPossible() {
            guard let scrollView = enclosingScrollView else { return }
            controller.attach(to: scrollView)
        }
    }
}

/// 8pt red dot with a manual 1.4s ease-in-out opacity pulse between 1.0 and
/// 0.5 — mirrors the §9.b "● Live" indicator spec. Plain SwiftUI animation
/// rather than `.symbolEffect(.pulse)` because the indicator is not an SF
/// Symbol (it's a filled `Circle`), and a hand-rolled pulse is more reliable
/// inside an NSHostingView.
struct LivePulseDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.5 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}
