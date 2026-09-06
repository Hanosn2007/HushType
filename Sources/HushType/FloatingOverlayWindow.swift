import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "overlay")

/// The transparent host includes shadow safety padding. This hosting view only
/// accepts pointer events inside the visible rounded pill, leaving its shadow
/// and the rest of the desktop click-through.
private final class PillHitTestingHostingView: NSHostingView<FloatingOverlayView> {
    var acceptsPillPointerEvents = false {
        didSet {
            if !acceptsPillPointerEvents {
                onPillHoverChanged?(false)
            }
            updateTrackingAreas()
        }
    }
    var onPillHoverChanged: ((Bool) -> Void)?

    private var pillTrackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsPillPointerEvents, pillPath.contains(point) else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let pillTrackingArea {
            removeTrackingArea(pillTrackingArea)
        }

        guard acceptsPillPointerEvents, !bounds.isEmpty else {
            pillTrackingArea = nil
            return
        }

        let area = NSTrackingArea(
            rect: pillRect,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pillTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard acceptsPillPointerEvents, pillPath.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        onPillHoverChanged?(true)
    }

    override func mouseMoved(with event: NSEvent) {
        guard acceptsPillPointerEvents else { return }
        onPillHoverChanged?(pillPath.contains(convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        onPillHoverChanged?(false)
    }

    private var pillRect: NSRect {
        let insets = FloatingOverlayAppearance.shadowInsets
        return NSRect(
            x: bounds.minX + insets.leading,
            y: bounds.minY + (isFlipped ? insets.top : insets.bottom),
            width: max(0, bounds.width - insets.leading - insets.trailing),
            height: max(0, bounds.height - insets.top - insets.bottom)
        )
    }

    private var pillPath: NSBezierPath {
        NSBezierPath(
            roundedRect: pillRect,
            xRadius: FloatingOverlayAppearance.cornerRadius,
            yRadius: FloatingOverlayAppearance.cornerRadius
        )
    }
}

/// Borderless floating panel that displays the recording/transcribing
/// indicator near the bottom of the screen.
///
/// Recording uses `.screenSaver` so it remains visible over fullscreen apps.
/// Model-operation notices deliberately use `.normal`; a work window can
/// cover them as soon as the user returns to it. The panel is non-activating
/// in either mode and never takes the user's keyboard focus.
final class FloatingOverlayWindow: NSPanel {

    private let stateModel: OverlayStateModel
    private var hostingView: PillHitTestingHostingView!
    private var presentationGeneration: UInt = 0
    private var pendingModelNoticeDismissal: DispatchWorkItem?
    private var isPresentingModelNotice = false
    private var onOpenModels: (() -> Void)?
    private var onOpenInputSettings: (() -> Void)?

    private let modelNoticeDisplayDuration: TimeInterval = 3

    init(stateModel: OverlayStateModel) {
        self.stateModel = stateModel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // we draw our own shadow inside the SwiftUI view
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = .screenSaver
        isMovable = false
        ignoresMouseEvents = true  // recording remains a pure indicator

        hostingView = PillHitTestingHostingView(
            rootView: FloatingOverlayView(
                model: stateModel,
                onOpenModels: { [weak self] in self?.openModels() },
                onOpenInputSettings: { [weak self] in self?.openInputSettings() }
            )
        )
        hostingView.onPillHoverChanged = { [weak self] isHovered in
            self?.setModelNoticeHovered(isHovered)
        }
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentView = hostingView
    }

    // Never become the key/main window — we must not steal focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show the recording overlay. This restores the original always-on-top,
    /// click-through behavior after a model notice was displayed.
    func show() {
        let generation = beginPresentation()
        isPresentingModelNotice = false
        onOpenModels = nil
        onOpenInputSettings = nil
        stateModel.isModelNoticeHovered = false
        configureRecordingWindow()
        positionAtBottomOfActiveScreen()
        fadeIn(for: generation, duration: 0.16)
        recenterAfterContentLayout(for: generation)
    }

    /// Keep the recording-level pill visible but make only its action button
    /// interactive so a failed device can route directly to its settings.
    func showConnectionFailure(onOpenSettings: @escaping () -> Void) {
        let generation = beginPresentation()
        isPresentingModelNotice = false
        onOpenModels = nil
        onOpenInputSettings = onOpenSettings
        stateModel.isModelNoticeHovered = false
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior.insert(.fullScreenAuxiliary)
        ignoresMouseEvents = false
        hostingView.acceptsPillPointerEvents = true
        positionAtBottomOfActiveScreen()
        if !isVisible {
            fadeIn(for: generation, duration: 0.16)
        }
        recenterAfterContentLayout(for: generation)
    }

    /// Show a short status notice for a model load/unload operation.
    ///
    /// The panel stays non-activating and uses the normal window level: it
    /// never takes keyboard focus and the user's work window may cover it.
    func showModelNotice(_ kind: ModelNoticeKind, onOpenModels: @escaping () -> Void) {
        let generation = beginPresentation()
        isPresentingModelNotice = true
        self.onOpenModels = onOpenModels
        stateModel.state = .modelNotice(kind)
        stateModel.isModelNoticeHovered = false
        configureModelNoticeWindow()
        positionAtBottomOfActiveScreen()
        fadeIn(for: generation, duration: 0.32) { [weak self] in
            guard let self,
                  self.presentationGeneration == generation,
                  self.isPresentingModelNotice,
                  !self.stateModel.isModelNoticeHovered else {
                return
            }
            self.scheduleModelNoticeDismissal(for: generation)
        }
    }

    /// Hide immediately, invalidating all pending delayed work and animation
    /// completions. The recording owner can safely call this before it shows
    /// its own separate overlay window.
    func hideImmediately() {
        _ = beginPresentation()
        let wasModelNotice = isPresentingModelNotice
        isPresentingModelNotice = false
        onOpenModels = nil
        onOpenInputSettings = nil
        stateModel.isModelNoticeHovered = false
        hostingView.acceptsPillPointerEvents = false
        ignoresMouseEvents = true
        alphaValue = 1
        orderOut(nil)
        if wasModelNotice {
            stateModel.state = .hidden
        }
    }

    /// Hide with a brief fade-out, then order out. A subsequent `show()` or
    /// `showModelNotice` changes the generation, so this completion cannot
    /// hide the newer presentation.
    func hide() {
        if isPresentingModelNotice {
            fadeOutModelNotice(for: presentationGeneration)
            return
        }

        let generation = beginPresentation()
        fadeOutAndOrderOut(for: generation)
    }

    private func configureRecordingWindow() {
        isFloatingPanel = true
        // AppKit resets the level when isFloatingPanel changes.
        level = .screenSaver
        collectionBehavior.insert(.fullScreenAuxiliary)
        ignoresMouseEvents = true
        hostingView.acceptsPillPointerEvents = false
    }

    private func configureModelNoticeWindow() {
        // Deliberately do not promote notices over normal work windows or
        // fullscreen content. It should be a brief hint, never a foreground
        // element competing with the user's active application.
        isFloatingPanel = false
        level = .normal
        collectionBehavior.remove(.fullScreenAuxiliary)
        ignoresMouseEvents = false
        hostingView.acceptsPillPointerEvents = true
    }

    private func positionAtBottomOfActiveScreen() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame

        // `fixedSize()` means the hosting view retains the original listening
        // pill's natural geometry. This includes its transparent shadow
        // padding, while the pill itself stays horizontally centered.
        let fittingSize = hostingView.fittingSize
        let shadowInsets = FloatingOverlayAppearance.shadowInsets
        let x = visible.midX - fittingSize.width / 2
            + (shadowInsets.trailing - shadowInsets.leading) / 2
        let y = visible.minY + 80 - shadowInsets.bottom
        setFrame(NSRect(origin: CGPoint(x: x, y: y), size: fittingSize), display: false)
    }

    /// ObservableObject changes reach NSHostingView on the next main-loop
    /// layout pass. Re-measure after that pass so a wide connecting pill that
    /// becomes the shorter listening pill shrinks around the screen center,
    /// instead of keeping its old left edge and pulling only the right edge in.
    private func recenterAfterContentLayout(for generation: UInt) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.presentationGeneration == generation,
                  !self.isPresentingModelNotice else { return }
            self.hostingView.layoutSubtreeIfNeeded()
            self.positionAtBottomOfActiveScreen()
        }
    }

    @discardableResult
    private func beginPresentation() -> UInt {
        presentationGeneration &+= 1
        pendingModelNoticeDismissal?.cancel()
        pendingModelNoticeDismissal = nil
        contentView?.layer?.removeAllAnimations()
        return presentationGeneration
    }

    private func fadeIn(
        for generation: UInt,
        duration: TimeInterval,
        completion: (() -> Void)? = nil
    ) {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            completion?()
        })
    }

    private func fadeOutModelNotice(for generation: UInt) {
        guard presentationGeneration == generation,
              isPresentingModelNotice,
              !stateModel.isModelNoticeHovered else {
            return
        }

        pendingModelNoticeDismissal?.cancel()
        pendingModelNoticeDismissal = nil
        hostingView.acceptsPillPointerEvents = false
        ignoresMouseEvents = true

        fadeOutAndOrderOut(for: generation) { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.stateModel.state = .hidden
            self.stateModel.isModelNoticeHovered = false
            self.isPresentingModelNotice = false
            self.onOpenModels = nil
        }
    }

    private func fadeOutAndOrderOut(for generation: UInt, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.orderOut(nil)
            completion?()
        })
    }

    func setModelNoticeHovered(_ isHovered: Bool) {
        guard isPresentingModelNotice, hostingView.acceptsPillPointerEvents else { return }
        guard stateModel.isModelNoticeHovered != isHovered else { return }
        stateModel.isModelNoticeHovered = isHovered

        if isHovered {
            pendingModelNoticeDismissal?.cancel()
            pendingModelNoticeDismissal = nil
        } else {
            scheduleModelNoticeDismissal(for: presentationGeneration)
        }
    }

    private func scheduleModelNoticeDismissal(for generation: UInt) {
        guard presentationGeneration == generation,
              isPresentingModelNotice,
              !stateModel.isModelNoticeHovered,
              pendingModelNoticeDismissal == nil else {
            return
        }

        let dismissal = DispatchWorkItem { [weak self] in
            self?.fadeOutModelNotice(for: generation)
        }
        pendingModelNoticeDismissal = dismissal
        DispatchQueue.main.asyncAfter(
            deadline: .now() + modelNoticeDisplayDuration,
            execute: dismissal
        )
    }

    private func openModels() {
        let action = onOpenModels
        hideImmediately()
        action?()
    }

    private func openInputSettings() {
        let action = onOpenInputSettings
        hideImmediately()
        action?()
    }
}
