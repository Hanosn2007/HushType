import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "polish-card")

private final class NonKeyPolishPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PolishHoverHostingView<V: View>: NSHostingView<V> {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
}

/// The polish card is deliberately non-key. It is shown only after
/// `TextInserter.insert` has completed, and can never steal the source app's
/// focus around the simulated paste.
final class PolishCardWindow {
    private static let autoDismissSeconds: TimeInterval = 10

    private var panel: NonKeyPolishPanel?
    private var globalClickMonitor: Any?
    private var autoDismissTimer: Timer?

    func show(originalText: String, polishedText: String, changed: Bool) {
        dismiss()

        let panel = NonKeyPolishPanel(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true

        let hostingView = PolishHoverHostingView(rootView: PolishCardView(
            originalText: originalText,
            polishedText: polishedText,
            changed: changed
        ))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.onMouseEntered = { [weak self] in self?.cancelAutoDismiss() }
        hostingView.onMouseExited = { [weak self] in self?.scheduleAutoDismiss() }
        panel.contentView = hostingView

        let fittingSize = hostingView.fittingSize
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrame(
                NSRect(
                    x: visible.midX - fittingSize.width / 2,
                    y: visible.midY - fittingSize.height / 2,
                    width: fittingSize.width,
                    height: fittingSize.height
                ),
                display: true
            )
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.dismiss()
        }
        scheduleAutoDismiss()
        log.info("Polish card shown")
    }

    private func scheduleAutoDismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = Timer.scheduledTimer(
            withTimeInterval: Self.autoDismissSeconds,
            repeats: false
        ) { [weak self] _ in self?.dismiss() }
    }

    private func cancelAutoDismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
    }

    func dismiss() {
        guard let panel else { return }
        cancelAutoDismiss()
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            panel.contentView = nil
            if self?.panel === panel {
                self?.panel = nil
            }
        })
        log.info("Polish card dismissed")
    }
}
