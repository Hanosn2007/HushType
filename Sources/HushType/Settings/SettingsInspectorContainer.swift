import AppKit
import SwiftUI

/// A window-edge pane. The root supplies the overlay and slide transition,
/// so neither resizing nor presentation changes the underlying page's width.
struct SettingsInspectorContainer<Content: View>: View {
    let maximumWidth: CGFloat
    @Binding var width: CGFloat
    @ViewBuilder var content: Content
    @State private var resizeOriginWidth: CGFloat?

    private var resolvedWidth: CGFloat {
        let maximum = maximumWidth.isFinite ? max(0, maximumWidth) : 420
        return min(maximum, max(min(320, maximum), width))
    }

    var body: some View {
        content
            .frame(width: resolvedWidth)
            .frame(maxHeight: .infinity)
            .clipped()
            .background { SettingsInspectorGlass() }
            .overlay(alignment: .leading) {
                Rectangle().fill(.primary.opacity(0.12)).frame(width: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .leading) {
                ProfileInspectorResizeHandle(
                    onBegan: { resizeOriginWidth = resolvedWidth },
                    onChanged: { translation in
                        width = min(maximumWidth, max(min(320, maximumWidth),
                            (resizeOriginWidth ?? resolvedWidth) - translation))
                    },
                    onEnded: { resizeOriginWidth = nil }
                )
                .frame(width: 8)
            }
    }
}

private struct SettingsInspectorGlass: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: Rectangle())
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }
}

/// The native hit view owns the cursor rect and reports horizontal movement
/// from the initial mouse-down point. Moving the left edge to the left grows
/// the inspector, so the SwiftUI owner subtracts this translation.
private struct ProfileInspectorResizeHandle: NSViewRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> ResizeHandleView {
        let view = ResizeHandleView()
        update(view)
        return view
    }

    func updateNSView(_ view: ResizeHandleView, context: Context) {
        update(view)
        view.window?.invalidateCursorRects(for: view)
    }

    private func update(_ view: ResizeHandleView) {
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
    }

    final class ResizeHandleView: NSView {
        var onBegan: (() -> Void)?
        var onChanged: ((CGFloat) -> Void)?
        var onEnded: (() -> Void)?
        private var initialWindowX: CGFloat?

        override var isOpaque: Bool { false }
        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            discardCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            initialWindowX = event.locationInWindow.x
            onBegan?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let initialWindowX else { return }
            onChanged?(event.locationInWindow.x - initialWindowX)
        }

        override func mouseUp(with event: NSEvent) {
            initialWindowX = nil
            onEnded?()
        }
    }
}
