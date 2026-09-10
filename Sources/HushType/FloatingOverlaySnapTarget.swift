import AppKit
import SwiftUI

/// The empty destination shown while a recording pill is being repositioned.
/// It deliberately has no shadow padding: its frame is the visible pill's
/// frame, which keeps its silhouette aligned with the draggable content.
final class FloatingOverlaySnapTargetWindow: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        if #available(macOS 26.0, *) {
            contentView = FloatingOverlayGlassView(frame: .zero)
        } else {
            contentView = NSHostingView(rootView: FloatingOverlaySnapTargetView())
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// ControlCenter's glass resolves its optical preset from AppKit's window
    /// appearance, independently of SwiftUI's materialActiveAppearance override.
    /// Keep this display-only guide visually active without acquiring keyboard
    /// focus. Do not override isKeyWindow or change NSApp.keyWindow.
    @objc(_hasActiveAppearance)
    private func hasActiveMaterialAppearance() -> Bool { true }

    func show(frame: NSRect, opacity: CGFloat) {
        if self.frame != frame {
            setFrame(frame, display: true)
        }
        if alphaValue != opacity {
            alphaValue = opacity
        }
        if !isVisible {
            orderFrontRegardless()
        }
    }

    func hide() {
        orderOut(nil)
    }
}

private struct FloatingOverlaySnapTargetView: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FloatingOverlayAppearance.cornerRadius, style: .continuous)
        Group {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.clear, in: shape)
            } else {
                shape.fill(.regularMaterial)
            }
        }
    }
}
