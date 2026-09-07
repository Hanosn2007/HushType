import AppKit
import SwiftUI

/// Keep standard titlebar dragging. Precise lower-edge expansion is deferred.
struct SettingsTitlebarDragRegion: View {
    var body: some View {
        if #available(macOS 15.0, *) {
            regionColor.contentShape(Rectangle()).gesture(WindowDragGesture())
        } else {
            LegacyTitlebarDragRegion()
        }
    }

    private var regionColor: Color {
        #if SETTINGS_PREVIEW
        Color.red.opacity(0.14)
        #else
        Color.clear
        #endif
    }
}

private struct LegacyTitlebarDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var isOpaque: Bool { false }
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
