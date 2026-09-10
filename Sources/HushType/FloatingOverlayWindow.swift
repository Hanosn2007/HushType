import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "overlay")

/// Placement rules kept independent from AppKit so the bounded drag behavior
/// can be tested without depending on the machine's connected displays.
enum FloatingOverlayPlacement {
    static let snapReleaseHysteresis: CGFloat = 4

    static func defaultFrame(
        in visibleFrame: NSRect,
        size: CGSize,
        shadowInsets: EdgeInsets
    ) -> NSRect {
        NSRect(
            x: visibleFrame.midX - size.width / 2
                + (shadowInsets.trailing - shadowInsets.leading) / 2,
            y: visibleFrame.minY + 80 - shadowInsets.bottom,
            width: size.width,
            height: size.height
        )
    }

    /// Keep the rendered pill on-screen while allowing the transparent shadow
    /// host to extend past an edge. `NSPanel.frame` includes that host padding.
    static func bounded(
        _ frame: NSRect,
        in visibleFrame: NSRect,
        shadowInsets: EdgeInsets
    ) -> NSRect {
        let lowerX = visibleFrame.minX - shadowInsets.leading
        let upperX = visibleFrame.maxX - frame.width + shadowInsets.trailing
        let lowerY = visibleFrame.minY - shadowInsets.bottom
        let upperY = visibleFrame.maxY - frame.height + shadowInsets.top
        return NSRect(
            x: min(max(frame.minX, min(lowerX, upperX)), max(lowerX, upperX)),
            y: min(max(frame.minY, min(lowerY, upperY)), max(lowerY, upperY)),
            width: frame.width,
            height: frame.height
        )
    }

    static func visiblePillFrame(for hostFrame: NSRect, shadowInsets: EdgeInsets) -> NSRect {
        NSRect(
            x: hostFrame.minX + shadowInsets.leading,
            y: hostFrame.minY + shadowInsets.bottom,
            width: max(0, hostFrame.width - shadowInsets.leading - shadowInsets.trailing),
            height: max(0, hostFrame.height - shadowInsets.top - shadowInsets.bottom)
        )
    }

    static func snappedOrigin(
        for proposedOrigin: CGPoint,
        defaultOrigin: CGPoint,
        wasSnapped: Bool,
        snapRadius: CGFloat
    ) -> (origin: CGPoint, isSnapped: Bool) {
        let distance = hypot(proposedOrigin.x - defaultOrigin.x, proposedOrigin.y - defaultOrigin.y)
        let limit = snapRadius + (wasSnapped ? snapReleaseHysteresis : 0)
        return distance <= limit ? (defaultOrigin, true) : (proposedOrigin, false)
    }

    /// Fade accelerates toward coincidence after the visible pills overlap.
    static func snapTargetOpacity(draggedPillFrame: NSRect, targetPillFrame: NSRect, exponent: CGFloat = 2) -> CGFloat {
        let overlap = draggedPillFrame.intersection(targetPillFrame)
        guard !overlap.isNull,
              draggedPillFrame.width > 0,
              draggedPillFrame.height > 0,
              targetPillFrame.width > 0,
              targetPillFrame.height > 0 else {
            return 1
        }
        let normalizer = min(draggedPillFrame.width * draggedPillFrame.height,
                             targetPillFrame.width * targetPillFrame.height)
        guard normalizer > 0 else { return 1 }
        let fraction = max(0, min(1, (overlap.width * overlap.height) / normalizer))
        let power = exponent.isFinite ? min(max(exponent, 1), 4) : 2
        return 1 - pow(fraction, power)
    }
}

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

    private struct DragSession {
        let initialFrame: NSRect
        let initialMouseLocation: NSPoint
        var isSnappedToDefault: Bool
    }

    private let stateModel: OverlayStateModel
    private var hostingView: PillHitTestingHostingView!
    private var presentationGeneration: UInt = 0
    private var pendingModelNoticeDismissal: DispatchWorkItem?
    private var isPresentingModelNotice = false
    private var onOpenModels: (() -> Void)?
    private var onOpenInputSettings: (() -> Void)?
    private var customCenter: CGPoint?
    private var dragSession: DragSession?
    private let snapTargetWindow = FloatingOverlaySnapTargetWindow()
    private var mouseEventMonitor: Any?
    private var screenParametersObserver: NSObjectProtocol?

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
        installMouseEventMonitor()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isVisible, !self.isPresentingModelNotice else { return }
            self.cancelDrag()
            self.positionAtBottomOfActiveScreen()
        }
    }

    deinit {
        if let mouseEventMonitor {
            NSEvent.removeMonitor(mouseEventMonitor)
        }
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    // Never become the key/main window — we must not steal focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show the recording overlay. The transparent host padding remains
    /// click-through; the visible pill accepts events so its body can move.
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
        isPresentingModelNotice = false
        onOpenModels = nil
        onOpenInputSettings = nil
        stateModel.isModelNoticeHovered = false
        hostingView.acceptsPillPointerEvents = false
        ignoresMouseEvents = true
        alphaValue = 1
        orderOut(nil)
        stateModel.state = .hidden
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
        ignoresMouseEvents = false
        hostingView.acceptsPillPointerEvents = true
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
        guard let activeScreen = NSScreen.main else { return }
        let visible = activeScreen.visibleFrame

        // `fixedSize()` means the hosting view retains the original listening
        // pill's natural geometry. This includes its transparent shadow
        // padding, while the pill itself stays horizontally centered.
        let fittingSize = hostingView.fittingSize
        if let center = customCenter {
            // A remembered point on a removed display is not useful. Return
            // to the familiar bottom-center default instead of stranding the
            // panel at a clipped edge of another display.
            guard let customScreen = screen(containing: center) else {
                customCenter = nil
                positionAtBottomOfActiveScreen()
                return
            }
            let proposed = NSRect(
                x: center.x - fittingSize.width / 2,
                y: center.y - fittingSize.height / 2,
                width: fittingSize.width,
                height: fittingSize.height
            )
            let bounded = FloatingOverlayPlacement.bounded(
                proposed,
                in: customScreen.visibleFrame,
                shadowInsets: FloatingOverlayAppearance.shadowInsets
            )
            customCenter = CGPoint(x: bounded.midX, y: bounded.midY)
            setFrame(bounded, display: false)
            return
        }

        setFrame(
            FloatingOverlayPlacement.defaultFrame(
                in: visible,
                size: fittingSize,
                shadowInsets: FloatingOverlayAppearance.shadowInsets
            ),
            display: false
        )
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
        cancelDrag()
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

    private func installMouseEventMonitor() {
        mouseEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleMouseEvent(event)
        }
    }

    /// Internal for the focused event-routing regression test. The local
    /// monitor calls this exact method in production.
    func handleMouseEvent(_ event: NSEvent) -> NSEvent? {
        guard event.window === self else { return event }

        switch event.type {
        case .leftMouseDown:
            guard !isPresentingModelNotice,
                  hostingView.acceptsPillPointerEvents,
                  isDraggablePillPoint(event.locationInWindow) else {
                return event
            }
            dragSession = DragSession(
                initialFrame: frame,
                initialMouseLocation: NSEvent.mouseLocation,
                isSnappedToDefault: customCenter == nil
            )
            let frameCenter = CGPoint(x: frame.midX, y: frame.midY)
            if let screen = screen(containing: frameCenter) {
                let defaultFrame = FloatingOverlayPlacement.defaultFrame(
                    in: screen.visibleFrame,
                    size: frame.size,
                    shadowInsets: FloatingOverlayAppearance.shadowInsets
                )
                updateSnapTarget(defaultFrame: defaultFrame, draggedFrame: frame)
            }
            NSCursor.closedHand.set()
            return nil

        case .leftMouseDragged:
            guard var dragSession else { return event }
            let mouse = NSEvent.mouseLocation
            let delta = CGPoint(
                x: mouse.x - dragSession.initialMouseLocation.x,
                y: mouse.y - dragSession.initialMouseLocation.y
            )
            let proposed = NSRect(
                x: dragSession.initialFrame.minX + delta.x,
                y: dragSession.initialFrame.minY + delta.y,
                width: dragSession.initialFrame.width,
                height: dragSession.initialFrame.height
            )
            let proposedCenter = CGPoint(x: proposed.midX, y: proposed.midY)
            guard let screen = screen(containing: mouse) ?? screen(containing: proposedCenter) else {
                return nil
            }
            let bounded = FloatingOverlayPlacement.bounded(
                proposed,
                in: screen.visibleFrame,
                shadowInsets: FloatingOverlayAppearance.shadowInsets
            )
            let defaultFrame = FloatingOverlayPlacement.defaultFrame(
                in: screen.visibleFrame,
                size: bounded.size,
                shadowInsets: FloatingOverlayAppearance.shadowInsets
            )
            let snap = FloatingOverlayPlacement.snappedOrigin(
                for: bounded.origin,
                defaultOrigin: defaultFrame.origin,
                wasSnapped: dragSession.isSnappedToDefault,
                snapRadius: FloatingOverlayDragPreferences.snapRadius
            )
            if !dragSession.isSnappedToDefault, snap.isSnapped {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            dragSession.isSnappedToDefault = snap.isSnapped
            self.dragSession = dragSession
            let snappedFrame = NSRect(origin: snap.origin, size: bounded.size)
            setFrame(snappedFrame, display: true)
            updateSnapTarget(defaultFrame: defaultFrame, draggedFrame: snappedFrame)
            return nil

        case .leftMouseUp:
            guard let dragSession else { return event }
            self.dragSession = nil
            snapTargetWindow.hide()
            customCenter = dragSession.isSnappedToDefault
                ? nil
                : CGPoint(x: frame.midX, y: frame.midY)
            NSCursor.arrow.set()
            return nil

        default:
            return event
        }
    }

    private func isDraggablePillPoint(_ point: NSPoint) -> Bool {
        let point = hostingView.convert(point, from: nil)
        guard hostingView.bounds.contains(point) else { return false }
        let insets = FloatingOverlayAppearance.shadowInsets
        let pillRect = NSRect(
            x: hostingView.bounds.minX + insets.leading,
            y: hostingView.bounds.minY + (hostingView.isFlipped ? insets.top : insets.bottom),
            width: max(0, hostingView.bounds.width - insets.leading - insets.trailing),
            height: max(0, hostingView.bounds.height - insets.top - insets.bottom)
        )
        let pillPath = NSBezierPath(
            roundedRect: pillRect,
            xRadius: FloatingOverlayAppearance.cornerRadius,
            yRadius: FloatingOverlayAppearance.cornerRadius
        )
        guard pillPath.contains(point), !actionButtonRect(in: pillRect).contains(point) else {
            return false
        }
        return true
    }

    private func actionButtonRect(in pillRect: NSRect) -> NSRect {
        guard hasVisibleActionButton else { return .null }
        // This exactly reserves the SwiftUI accessory slot around the button;
        // it keeps a press or drag on the action in SwiftUI's normal control
        // path rather than turning it into a window drag.
        return NSRect(
            x: pillRect.maxX - 18 - 44,
            y: pillRect.minY,
            width: 44,
            height: pillRect.height
        )
    }

    private var hasVisibleActionButton: Bool {
        switch stateModel.state {
        case .connectionFailed, .connectionDisconnected:
            return true
        case .modelNotice:
            return stateModel.isModelNoticeHovered
        default:
            return false
        }
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func cancelDrag() {
        guard dragSession != nil else { return }
        dragSession = nil
        snapTargetWindow.hide()
        NSCursor.arrow.set()
    }

    private func updateSnapTarget(defaultFrame: NSRect, draggedFrame: NSRect) {
        let insets = FloatingOverlayAppearance.shadowInsets
        let targetPillFrame = FloatingOverlayPlacement.visiblePillFrame(
            for: defaultFrame,
            shadowInsets: insets
        )
        let draggedPillFrame = FloatingOverlayPlacement.visiblePillFrame(
            for: draggedFrame,
            shadowInsets: insets
        )
        snapTargetWindow.show(
            frame: targetPillFrame,
            opacity: FloatingOverlayPlacement.snapTargetOpacity(
                draggedPillFrame: draggedPillFrame,
                targetPillFrame: targetPillFrame,
                exponent: FloatingOverlayDragPreferences.fadeExponent
            )
        )
    }
}
