import AppKit
import SwiftUI

/// Pure geometry for the caption panel. Keeping the limits independent from
/// `NSScreen` and `NSPanel` makes the intended sizing policy directly testable.
struct LiveCaptionWindowSizing {
    struct Limits: Equatable {
        let minimum: NSSize
        let maximum: NSSize
    }

    static let minimumSize = NSSize(width: 230, height: 90)
    static let preferredMaximumWidth: CGFloat = 720
    static let preferredMaximumHeight: CGFloat = 420
    static let screenHorizontalMargin: CGFloat = 40

    static func limits(in visibleFrame: NSRect, configuration: LiveCaptionPresentationConfiguration = .defaults) -> Limits {
        Limits(
            minimum: minimumSize,
            maximum: NSSize(
                width: max(
                    minimumSize.width,
                    min(configuration.maximumAutomaticWidth, visibleFrame.width - screenHorizontalMargin)
                ),
                height: max(
                    minimumSize.height,
                    min(configuration.maximumAutomaticHeight, visibleFrame.height - screenHorizontalMargin)
                )
            )
        )
    }

    static func automaticSize(contentSize: NSSize, limits: Limits) -> NSSize {
        NSSize(
            width: min(max(contentSize.width, limits.minimum.width), limits.maximum.width),
            height: min(max(contentSize.height, limits.minimum.height), limits.maximum.height)
        )
    }

    /// Keep a growing caption pinned around its current horizontal center and
    /// lower edge, then constrain it to the active screen's usable bounds.
    static func frame(
        size: NSSize,
        preservingBottomCenterOf existingFrame: NSRect,
        in visibleFrame: NSRect
    ) -> NSRect {
        let proposed = NSPoint(
            x: existingFrame.midX - size.width / 2,
            y: existingFrame.minY
        )
        return constrainedFrame(size: size, origin: proposed, in: visibleFrame)
    }

    static func defaultFrame(size: NSSize, in visibleFrame: NSRect) -> NSRect {
        let verticalSlack = max(0, visibleFrame.height - size.height)
        let proposed = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + min(80, verticalSlack)
        )
        return constrainedFrame(size: size, origin: proposed, in: visibleFrame)
    }

    private static func constrainedFrame(size: NSSize, origin: NSPoint, in visibleFrame: NSRect) -> NSRect {
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - size.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - size.height)
        return NSRect(
            x: min(max(origin.x, visibleFrame.minX), maximumX),
            y: min(max(origin.y, visibleFrame.minY), maximumY),
            width: size.width,
            height: size.height
        )
    }
}

/// Guards against an old fade-out completion ordering out a newly shown
/// panel. The actual animation remains AppKit-owned; this only validates the
/// delayed completion side effect.
struct LiveCaptionVisibilityState: Equatable {
    private(set) var generation: UInt64 = 0

    mutating func beginShow() {
        generation &+= 1
    }

    mutating func beginHide() -> UInt64 {
        generation &+= 1
        return generation
    }

    func shouldFinishHide(_ token: UInt64) -> Bool {
        token == generation
    }
}

/// Bottom-pinned translucent panel that hosts the live caption stream.
///
/// The panel is native-resizable and never steals main-window status. Its
/// frame follows the full session transcript until the user resizes it, at
/// which point native sizing takes over for the rest of that caption session.
enum LiveCaptionHeaderHitRegion {
    static func isDraggable(_ point: NSPoint, size: NSSize, showsRestore: Bool) -> Bool {
        // Preserve native resize edges and leave every control's full hit box.
        guard point.x >= 5, point.x <= size.width - 5,
              point.y >= size.height - 32, point.y <= size.height - 5 else { return false }
        let controlY = size.height - 26
        var controls = [
            NSRect(x: 6, y: controlY, width: 20, height: 20),
            NSRect(x: size.width - 26, y: controlY, width: 20, height: 20)
        ]
        if showsRestore { controls.append(NSRect(x: 34, y: controlY, width: 20, height: 20)) }
        return !controls.contains { $0.contains(point) }
    }
}

final class LiveCaptionWindow: NSPanel, NSWindowDelegate {

    private enum LayoutMetrics {
        static let horizontalContentInsets: CGFloat = 36
        static let chromeHeight: CGFloat = 57
        static let historySpacing: CGFloat = 4
        static let historyTranslationSpacing: CGFloat = 3
        static let currentRegionSpacing: CGFloat = 6
        static let translationStatusSpacing: CGFloat = 4
        static let translationStatusVerticalInsets: CGFloat = 10
        static let dualLineTextInsets: CGFloat = 150
        static let bodyFont = NSFont.systemFont(ofSize: 17, weight: .regular)
        static let translatedSourceFont = NSFont.systemFont(ofSize: 14, weight: .regular)
        static let translationStatusFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        static let headerFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        static let costFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    }

    private let viewModel: LiveCaptionViewModel
    private var automaticResizeWork: DispatchWorkItem?
    private var automaticResizeGeneration: UInt64 = 0
    private var frameAnimationTimer: DispatchSourceTimer?
    private var frameAnimationGeneration: UInt64 = 0
    private var visibilityState = LiveCaptionVisibilityState()
    private var isUserResizing = false
    private var configuration = LiveCaptionPresentationConfiguration.load()
    private var configurationObserver: NSObjectProtocol?
    private let snapTargetWindow = FloatingOverlaySnapTargetWindow()
    private var isUserMoving = false
    private var moveEndTimer: DispatchSourceTimer?
    private var isSettingFrameProgrammatically = false
    private struct DragSession {
        let initialFrame: NSRect
        let initialPointer: NSPoint
        var isSnapped: Bool
    }
    private var dragSession: DragSession?
    private let pointerLocation: () -> NSPoint
    private let alignmentHaptic: () -> Void

    init(
        viewModel: LiveCaptionViewModel, tuning _: LiveCaptionTuning,
        pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
        alignmentHaptic: @escaping () -> Void = {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        },
        onStop: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.pointerLocation = pointerLocation
        self.alignmentHaptic = alignmentHaptic

        super.init(
            contentRect: NSRect(origin: .zero, size: LiveCaptionWindowSizing.minimumSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        // Let AppKit draw the external shadow. A SwiftUI shadow expands the
        // hosted view's hit area and blocks native resize edges around a
        // borderless panel.
        hasShadow = true
        // Setting `isFloatingPanel` also changes the window level. Set it
        // before the required screen-saver level so captions remain above
        // fullscreen presentation surfaces.
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = false

        if let visibleFrame = activeVisibleFrame() {
            applySizeLimits(in: visibleFrame)
        } else {
            minSize = LiveCaptionWindowSizing.minimumSize
            maxSize = NSSize(
                width: LiveCaptionWindowSizing.preferredMaximumWidth,
                height: LiveCaptionWindowSizing.preferredMaximumHeight
            )
        }

        let hostingView = NSHostingView(
            rootView: LiveCaptionView(model: viewModel, onStop: onStop)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentView = hostingView

        viewModel.onContentSizeInvalidated = { [weak self] in
            self?.scheduleAutomaticResize()
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let updated = LiveCaptionPresentationConfiguration.load()
            guard self.configuration != updated else { return }
            self.configuration = updated
            self.scheduleAutomaticResize()
        }
        delegate = self
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        frameAnimationTimer?.cancel()
        moveEndTimer?.cancel()
    }

    // Need key for Esc handling, but never main (don't steal focus).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Every show begins a new automatic layout pass. The frame deliberately
    /// stays in memory only: the caption session owns its manual resize, and
    /// no old UserDefaults frame is read, migrated, or deleted here.
    func show() {
        visibilityState.beginShow()
        cancelAutomaticResize()
        cancelFrameAnimation()
        configuration = .load()
        viewModel.resetSizingForNewSession()

        guard let visibleFrame = activeVisibleFrame() else {
            alphaValue = 1
            orderFrontRegardless()
            return
        }

        applySizeLimits(in: visibleFrame)
        let size = desiredAutomaticSize(in: visibleFrame)
        setPanelFrame(
            LiveCaptionWindowSizing.defaultFrame(size: size, in: visibleFrame),
            display: false
        )

        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    /// Fade out without letting an older completion hide a new session.
    func hide() {
        finishUserMove(snap: false)
        cancelAutomaticResize()
        cancelFrameAnimation()
        let token = visibilityState.beginHide()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.visibilityState.shouldFinishHide(token) else { return }
            self.orderOut(nil)
        })
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard let visibleFrame = activeVisibleFrame() else { return }
        applySizeLimits(in: visibleFrame)
        guard isUserMoving, !isSettingFrameProgrammatically else { return }
        updateSnapTarget(in: visibleFrame)
    }

    private func beginUserMove() {
        guard !isUserResizing else { return }
        isUserMoving = true
        cancelAutomaticResize()
        cancelFrameAnimation()
        let visible = activeVisibleFrame() ?? frame
        let target = LiveCaptionWindowSizing.defaultFrame(size: frame.size, in: visible)
        dragSession = DragSession(
            initialFrame: frame, initialPointer: pointerLocation(),
            isSnapped: hypot(frame.minX - target.minX, frame.minY - target.minY) <= LiveCaptionDragPreferences.snapRadius
        )
        updateSnapTarget(in: visible)
        moveEndTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(40), repeating: .milliseconds(40))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Native dragging may consume mouse-up inside its tracking loop.
            if NSEvent.pressedMouseButtons & 1 == 0 { self.finishUserMove() }
        }
        moveEndTimer = timer
        timer.resume()
    }

    override func sendEvent(_ event: NSEvent) {
        if handleHeaderDragEvent(event) { return }
        super.sendEvent(event)
    }

    /// Hit geometry is read from the current frame at press time; it cannot
    /// lag behind an automatic width animation or be covered by SwiftUI text.
    @discardableResult
    func handleHeaderDragEvent(_ event: NSEvent) -> Bool {
        guard event.window === self else { return false }
        switch event.type {
        case .leftMouseDown:
            guard LiveCaptionHeaderHitRegion.isDraggable(
                event.locationInWindow, size: frame.size,
                showsRestore: viewModel.sizingState.showsRestoreControl
            ) else { return false }
            beginUserMove()
            return true
        case .leftMouseDragged:
            guard var session = dragSession else { return false }
            let pointer = pointerLocation()
            let proposed = session.initialFrame.offsetBy(
                dx: pointer.x - session.initialPointer.x, dy: pointer.y - session.initialPointer.y
            )
            let visible = NSScreen.screens.first(where: { $0.frame.contains(pointer) })?.visibleFrame
                ?? activeVisibleFrame() ?? proposed
            let bounded = LiveCaptionWindowSizing.frame(
                size: proposed.size, preservingBottomCenterOf: proposed, in: visible
            )
            let target = LiveCaptionWindowSizing.defaultFrame(size: bounded.size, in: visible)
            let placement = LiveCaptionDragPreferences.snappingEnabled
                ? FloatingOverlayPlacement.snappedOrigin(
                    for: bounded.origin, defaultOrigin: target.origin,
                    wasSnapped: session.isSnapped, snapRadius: LiveCaptionDragPreferences.snapRadius
                ) : (origin: bounded.origin, isSnapped: false)
            if placement.isSnapped, !session.isSnapped, LiveCaptionDragPreferences.hapticsEnabled {
                alignmentHaptic()
            }
            session.isSnapped = placement.isSnapped
            dragSession = session
            setPanelFrame(NSRect(origin: placement.origin, size: bounded.size), display: true)
            updateSnapTarget(in: visible)
            return true
        case .leftMouseUp:
            guard dragSession != nil else { return false }
            finishUserMove()
            return true
        default:
            return false
        }
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        isUserResizing = true
        cancelAutomaticResize()
        cancelFrameAnimation()
        if let visibleFrame = activeVisibleFrame() {
            applySizeLimits(in: visibleFrame)
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard isUserResizing else { return }
        viewModel.useManualSizing()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        isUserResizing = false
        if let visibleFrame = activeVisibleFrame() {
            applySizeLimits(in: visibleFrame)
        }
        scheduleAutomaticResize()
    }

    // MARK: - Automatic sizing

    private func scheduleAutomaticResize() {
        guard viewModel.sizingState.acceptsAutomaticResizing,
              !isUserResizing,
              !isUserMoving,
              isVisible else { return }
        guard automaticResizeWork == nil else { return }

        let generation = automaticResizeGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.automaticResizeGeneration == generation else { return }
            self.automaticResizeWork = nil
            self.applyAutomaticResize()
        }
        automaticResizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func applyAutomaticResize() {
        guard viewModel.sizingState.acceptsAutomaticResizing,
              !isUserResizing,
              !isUserMoving,
              isVisible,
              let visibleFrame = activeVisibleFrame() else { return }

        applySizeLimits(in: visibleFrame)
        let size = desiredAutomaticSize(in: visibleFrame)
        let target = LiveCaptionWindowSizing.frame(
            size: size,
            preservingBottomCenterOf: frame,
            in: visibleFrame
        )
        guard !frame.equalTo(target) else { return }

        animateFrame(to: target)
    }

    private func desiredAutomaticSize(in visibleFrame: NSRect) -> NSSize {
        let limits = LiveCaptionWindowSizing.limits(in: visibleFrame, configuration: configuration)
        let visibleSegments = viewModel.segments.suffix(configuration.maximumAutomaticSentences)
        let timestampWidth: CGFloat = UserDefaults.standard.bool(forKey: "hushtype.liveCaption.showsTimestamps") ? 70 : 0
        let widestVisibleText = visibleSegments.map { widestHistoryTextWidth(for: $0) }.max() ?? 0

        let currentSource = viewModel.currentSourceLine?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentTarget = viewModel.currentTargetLine?.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeLines: [String] = [currentSource, currentTarget].compactMap { text in
            guard let text, !text.isEmpty else { return nil }
            return text
        }
        let translationStatus = viewModel.translationStatusText

        var proposedWidth = max(
            LiveCaptionWindowSizing.minimumSize.width,
            widestVisibleText + LayoutMetrics.horizontalContentInsets + timestampWidth
        )
        proposedWidth = max(proposedWidth, requiredHeaderWidth())
        for text in activeLines {
            proposedWidth = max(
                proposedWidth,
                singleLineWidth(of: text) + LayoutMetrics.dualLineTextInsets
            )
        }
        if let translationStatus {
            proposedWidth = max(
                proposedWidth,
                singleLineWidth(of: translationStatus, font: LayoutMetrics.translationStatusFont)
                    + LayoutMetrics.horizontalContentInsets
            )
        }
        proposedWidth = min(proposedWidth, limits.maximum.width)

        let historyTextWidth = max(1, proposedWidth - LayoutMetrics.horizontalContentInsets - timestampWidth)
        let dualLineTextWidth = max(1, proposedWidth - LayoutMetrics.dualLineTextInsets)
        let bodyHeightLimit = max(0, limits.maximum.height - LayoutMetrics.chromeHeight)

        var bodyHeight: CGFloat = 0
        for entry in visibleSegments {
            if bodyHeight > 0 {
                bodyHeight += LayoutMetrics.historySpacing
            }
            bodyHeight += measuredHistoryHeight(entry, constrainedTo: historyTextWidth)
            if bodyHeight >= bodyHeightLimit {
                return LiveCaptionWindowSizing.automaticSize(
                    contentSize: NSSize(
                        width: proposedWidth,
                        height: LayoutMetrics.chromeHeight + bodyHeight
                    ),
                    limits: limits
                )
            }
        }

        if !activeLines.isEmpty {
            if bodyHeight > 0 {
                bodyHeight += LayoutMetrics.currentRegionSpacing
            }
            for index in activeLines.indices {
                if index > activeLines.startIndex {
                    bodyHeight += LayoutMetrics.currentRegionSpacing
                }
                bodyHeight += measuredTextHeight(activeLines[index], constrainedTo: dualLineTextWidth)
            }
        }

        if let translationStatus, !translationStatus.isEmpty {
            if bodyHeight > 0 {
                bodyHeight += LayoutMetrics.translationStatusSpacing
            }
            bodyHeight += measuredTextHeight(
                translationStatus,
                constrainedTo: historyTextWidth,
                font: LayoutMetrics.translationStatusFont
            )
            bodyHeight += LayoutMetrics.translationStatusVerticalInsets
        }

        return LiveCaptionWindowSizing.automaticSize(
            contentSize: NSSize(
                width: proposedWidth,
                height: LayoutMetrics.chromeHeight + bodyHeight
            ),
            limits: limits
        )
    }

    /// Header labels are real content too. In particular, a loading-model
    /// label must widen a fresh, otherwise empty panel instead of wrapping
    /// underneath the permanent close control.
    private func requiredHeaderWidth() -> CGFloat {
        let leftWidth: CGFloat
        switch viewModel.headerState {
        case .finishing:
            leftWidth = singleLineWidth(of: L10n.string("overview.finishing", fallback: "Finishing"), font: LayoutMetrics.headerFont)
        case .stopped:
            leftWidth = singleLineWidth(of: L10n.string("settings.captions.status.stopped", fallback: "Stopped"), font: LayoutMetrics.headerFont)
        case .loadingModel(let progress):
            let label = L10n.format(
                "caption.loading_speech_model",
                "Loading speech model… %1$d%%",
                arguments: [Int32(Int(max(0, min(1, progress)) * 100))]
            )
            leftWidth = 64 + 6 + singleLineWidth(of: label, font: LayoutMetrics.headerFont)
        case .loadingVAD:
            let label = L10n.string("caption.loading_vad", fallback: "Loading VAD model…")
            leftWidth = 14 + 6 + singleLineWidth(of: label, font: LayoutMetrics.headerFont)
        case .live:
            let label = AppConfig.shared.liveCaptionEngine == .cloudTranslate
                ? L10n.string("caption.live_translated", fallback: "Live · Translated")
                : L10n.string("caption.live", fallback: "Live")
            leftWidth = 8 + 8 + singleLineWidth(of: label, font: LayoutMetrics.headerFont)
        case .gatedFlash:
            let label = L10n.string(
                "caption.stop_to_dictate",
                fallback: "Stop Live Caption to dictate"
            )
            leftWidth = singleLineWidth(of: label, font: LayoutMetrics.headerFont)
        case .reconnecting(let attempt, let maximum):
            let label = L10n.format(
                "caption.reconnecting",
                "Reconnecting (%1$d/%2$d)…",
                arguments: [Int32(attempt), Int32(maximum)]
            )
            leftWidth = 14 + 6 + singleLineWidth(of: label, font: LayoutMetrics.headerFont)
        case .autoStopped:
            let label = L10n.string("caption.auto_stopped", fallback: "Auto-stopped")
            leftWidth = singleLineWidth(of: label, font: LayoutMetrics.headerFont)
        }

        // Close control + its HStack spacing + the current header content.
        var width: CGFloat = 12 + 20 + 8 + leftWidth + 8 + 20
        if let costChip = viewModel.cloudCostChip, !costChip.isEmpty {
            width += 8 + singleLineWidth(of: costChip, font: LayoutMetrics.costFont)
        }
        return width
    }

    private func singleLineWidth(of text: String, font: NSFont = LayoutMetrics.bodyFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func widestHistoryTextWidth(for entry: LiveCaptionViewModel.SegmentEntry) -> CGFloat {
        var widest = singleLineWidth(
            of: entry.text,
            font: entry.hasTranslatedText ? LayoutMetrics.translatedSourceFont : LayoutMetrics.bodyFont
        )
        if let translatedText = entry.translatedText, entry.hasTranslatedText {
            widest = max(widest, singleLineWidth(of: translatedText))
        }
        if let translationError = entry.translationError,
           !translationError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            widest = max(
                widest,
                singleLineWidth(of: translationError, font: LayoutMetrics.translationStatusFont)
            )
        }
        return widest
    }

    private func measuredHistoryHeight(
        _ entry: LiveCaptionViewModel.SegmentEntry,
        constrainedTo width: CGFloat
    ) -> CGFloat {
        var height = measuredTextHeight(
            entry.text,
            constrainedTo: width,
            font: entry.hasTranslatedText ? LayoutMetrics.translatedSourceFont : LayoutMetrics.bodyFont
        )
        if let translatedText = entry.translatedText, entry.hasTranslatedText {
            height += LayoutMetrics.historyTranslationSpacing
            height += measuredTextHeight(translatedText, constrainedTo: width)
        }
        if let translationError = entry.translationError,
           !translationError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            height += LayoutMetrics.historyTranslationSpacing
            height += measuredTextHeight(
                translationError,
                constrainedTo: width,
                font: LayoutMetrics.translationStatusFont
            )
        }
        return height
    }

    private func measuredTextHeight(
        _ text: String,
        constrainedTo width: CGFloat,
        font: NSFont = LayoutMetrics.bodyFont
    ) -> CGFloat {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 1
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle,
            ]
        )
        return ceil(rect.height)
    }

    private func cancelAutomaticResize() {
        automaticResizeGeneration &+= 1
        automaticResizeWork?.cancel()
        automaticResizeWork = nil
    }

    /// Frame animation is driven by our own main-queue timer, rather than an
    /// opaque `NSWindow.animator()` transaction. Each tick writes the actual
    /// frame, so cancellation leaves the panel exactly where it is when the
    /// user grabs a native resize edge or another caption update arrives.
    private func animateFrame(to target: NSRect) {
        cancelFrameAnimation()
        let initialFrame = frame
        let startedAt = Date.timeIntervalSinceReferenceDate
        let generation = frameAnimationGeneration
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self, weak timer] in
            guard let self, self.frameAnimationGeneration == generation else {
                timer?.cancel()
                return
            }

            let progress = CGFloat(min(1, (Date.timeIntervalSinceReferenceDate - startedAt) / 0.20))
            let easedProgress = progress * progress * (3 - 2 * progress)
            self.setPanelFrame(
                self.interpolatedFrame(from: initialFrame, to: target, progress: easedProgress),
                display: true
            )
            guard progress >= 1 else { return }
            timer?.cancel()
            self.frameAnimationTimer = nil
        }
        frameAnimationTimer = timer
        timer.resume()
    }

    private func interpolatedFrame(from initial: NSRect, to target: NSRect, progress: CGFloat) -> NSRect {
        NSRect(
            x: initial.origin.x + (target.origin.x - initial.origin.x) * progress,
            y: initial.origin.y + (target.origin.y - initial.origin.y) * progress,
            width: initial.width + (target.width - initial.width) * progress,
            height: initial.height + (target.height - initial.height) * progress
        )
    }

    private func cancelFrameAnimation() {
        frameAnimationGeneration &+= 1
        frameAnimationTimer?.cancel()
        frameAnimationTimer = nil
    }

    private func setPanelFrame(_ frame: NSRect, display: Bool) {
        isSettingFrameProgrammatically = true
        defer { isSettingFrameProgrammatically = false }
        setFrame(frame, display: display, animate: false)
    }

    var isSnapGuideVisible: Bool { snapTargetWindow.isVisible }

    private func updateSnapTarget(in visibleFrame: NSRect) {
        let target = LiveCaptionWindowSizing.defaultFrame(size: frame.size, in: visibleFrame)
        snapTargetWindow.show(
            frame: target,
            opacity: FloatingOverlayPlacement.snapTargetOpacity(
                draggedPillFrame: frame, targetPillFrame: target,
                exponent: LiveCaptionDragPreferences.fadeExponent
            ), enabled: LiveCaptionDragPreferences.guideEnabled,
            maximumOpacity: LiveCaptionDragPreferences.guideOpacity
        )
    }

    func finishUserMove(snap: Bool = true) {
        let wasMoving = isUserMoving
        isUserMoving = false
        dragSession = nil
        moveEndTimer?.cancel()
        moveEndTimer = nil
        snapTargetWindow.hide()
        guard wasMoving, snap else { return }
        scheduleAutomaticResize()
    }

    private func activeVisibleFrame() -> NSRect? {
        screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
    }

    private func applySizeLimits(in visibleFrame: NSRect) {
        // Automatic fitting remains capped by `LiveCaptionWindowSizing`; the
        // native resize affordance may use all of the active visible screen.
        minSize = LiveCaptionWindowSizing.minimumSize
        maxSize = NSSize(
            width: max(minSize.width, visibleFrame.width),
            height: max(minSize.height, visibleFrame.height)
        )
    }
}
