import AppKit
import SwiftUI

/// An AppKit responder deliberately owns only the empty titlebar space.
///
/// `WindowDragGesture` shares SwiftUI's gesture arena with controls that are
/// visually above it, which can turn a button drag into both a window drag and
/// a button activation. Handling the empty area in AppKit keeps controls out
/// of that responder path and preserves the normal titlebar double-click zoom.
struct SettingsTitlebarDragRegion: NSViewRepresentable {
    let registry: SettingsTitlebarDragExclusionRegistry

    func makeNSView(context: Context) -> DragView { DragView(registry: registry) }
    func updateNSView(_ view: DragView, context: Context) {
        view.registry = registry
    }

    final class DragView: NSView {
        private var restoredFrame: NSRect?
        var registry: SettingsTitlebarDragExclusionRegistry

        init(registry: SettingsTitlebarDragExclusionRegistry) {
            self.registry = registry
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override var isOpaque: Bool { false }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            // The reporter resolves its current bounds in this exact window
            // coordinate space. This excludes the full live navigation
            // capsule without fixed coordinates or a delayed SwiftUI frame.
            guard !registry.contains(event.locationInWindow, in: window) else {
                return
            }
            if event.clickCount == 2 {
                performConfiguredDoubleClickAction()
                return
            }
            window.performDrag(with: event)
        }

        private func performConfiguredDoubleClickAction() {
            guard let window else { return }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Maximize":
                toggleMaximizedFrame(of: window)
            case "Zoom":
                window.performZoom(nil)
            case "Minimize":
                window.performMiniaturize(nil)
            case "None":
                break
            default:
                // Keep an unknown (including legacy) preference on AppKit's
                // standard zoom path instead of assuming it means Maximize.
                window.performZoom(nil)
            }
        }

        /// For the system's explicit "Maximize" option, `performZoom` can
        /// restore AppKit's content-derived standard frame, which may be
        /// unchanged for this content-sized SwiftUI scene. Fill the active
        /// screen's visible frame instead, then retain the exact prior frame
        /// for the next double-click.
        private func toggleMaximizedFrame(of window: NSWindow) {
            guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            if let restoredFrame, window.frame.equalTo(visibleFrame) {
                window.setFrame(restoredFrame, display: true, animate: true)
                self.restoredFrame = nil
            } else {
                restoredFrame = window.frame
                window.setFrame(visibleFrame, display: true, animate: true)
            }
        }
    }
}
