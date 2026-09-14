import AppKit
import SwiftUI

/// One retained hosting view moves as a unit. Reversing direction reuses its
/// presentation position; nested native glass controls never get reinserted.
struct SettingsInspectorPresentation<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let width: CGFloat
    let reduceMotion: Bool
    var showsToggle = false
    var headerCenterY: CGFloat = 28
    var rightInset: CGFloat = 8
    var toggle: () -> Void = {}
    var dockAnchor: SettingsInspectorDockAnchor? = nil
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> PaneView { PaneView() }
    func updateNSView(_ view: PaneView, context: Context) {
        view.setContent(AnyView(content.transaction { $0.animation = nil }))
        view.setToggle(visible: showsToggle, centerY: headerCenterY, rightInset: rightInset,
                       presented: isPresented, dockAnchor: dockAnchor, action: toggle)
        view.configure(width: width, presented: isPresented, animated: !reduceMotion)
    }

    final class PaneView: NSView {
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let toggleHost = NSHostingView(rootView: AnyView(EmptyView()))
        private var toggleVisible = false
        private var toggleCenterY: CGFloat = 28
        private var toggleRightInset: CGFloat = 8
        private weak var dockAnchor: SettingsInspectorDockAnchor?
        private var transitionGeneration = 0
        private var transitioning = false
        private var buttonPresented: Bool?
        private weak var buttonCutoutRegistry: SettingsAdaptiveCutoutRegistry?
        private var toggleAction: (() -> Void)?
        private var paneWidth: CGFloat = 420
        private var presented = false
        private var configured = false
        private var previousSize: CGSize = .zero
        private static var toggleMotionKey: String { "inspectorTogglePosition" }
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            host.sizingOptions = []
            addSubview(host)
            toggleHost.sizingOptions = []
            // This small host is already positioned by the toolbar. Window
            // safe-area expansion would move its glass inside the 48pt frame.
            toggleHost.safeAreaRegions = []
            addSubview(toggleHost)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func setContent(_ content: AnyView) {
            // This is a second SwiftUI hosting boundary. Ignoring the titlebar
            // on the outer settings root does not carry into this hosting view.
            // The shared header already supplies the measured chrome spacing.
            host.rootView = AnyView(content.ignoresSafeArea(.container, edges: .top))
        }

        func setToggle(visible: Bool, centerY: CGFloat, rightInset: CGFloat,
                       presented: Bool, dockAnchor: SettingsInspectorDockAnchor? = nil, action: @escaping () -> Void) {
            let geometryChanged = toggleVisible != visible || toggleCenterY != centerY || toggleRightInset != rightInset
            if self.dockAnchor !== dockAnchor {
                self.dockAnchor?.onSlotChange = nil
                self.dockAnchor = dockAnchor
                dockAnchor?.onSlotChange = { [weak self] in
                    guard let self else { return }
                    self.updateToggleSurface(presented: self.buttonPresented ?? self.presented)
                    self.dockToggleIfClosed()
                }
            }
            toggleAction = action
            toggleVisible = visible
            toggleCenterY = centerY
            toggleRightInset = rightInset
            toggleHost.isHidden = !visible
            updateToggleSurface(presented: presented)
            toggleHost.setFrameSize(CGSize(width: 48, height: 48))
            if geometryChanged, toggleHost.superview === self { toggleHost.setFrameOrigin(toggleOrigin) }
        }

        private func updateToggleSurface(presented: Bool) {
            let registry = dockAnchor?.cutoutRegistry
            guard buttonPresented != presented || buttonCutoutRegistry !== registry else { return }
            buttonPresented = presented
            buttonCutoutRegistry = registry
            toggleHost.rootView = AnyView(SettingsClickOnlyIconButton(
                symbolName: presented ? "arrow.right" : "slider.horizontal.3",
                label: L10n.string(presented ? "profiles.inspector.close" : "inspector.open",
                                  fallback: presented ? "Close configuration editor" : "Open configuration editor"),
                isEnabled: true, action: { [weak self] in self?.toggleAction?() })
                .frame(width: 36, height: 36).modifier(ProfileInspectorCloseSurface())
                .settingsBackdropCutout(id: "inspector-toggle")
                .environment(\.settingsAdaptiveCutoutRegistry, registry)
                .padding(6))
        }

        private var toggleOrigin: CGPoint {
            if !presented, let slot = dockAnchor?.slot, window != nil, slot.window === window {
                return slot.convert(slot.bounds, to: self).insetBy(dx: -6, dy: -6).origin
            }
            return CGPoint(x: presented ? bounds.width - paneWidth + 10 : bounds.width - toggleRightInset - 42,
                    y: toggleCenterY - 24)
        }

        private func dockToggleIfClosed() {
            guard !presented, !transitioning, let slot = dockAnchor?.slot else { return }
            if toggleHost.superview !== slot { slot.addSubview(toggleHost) }
            toggleHost.autoresizingMask = [.width, .height]
            toggleHost.frame = slot.bounds.insetBy(dx: -6, dy: -6)
        }

        @discardableResult
        private func moveToggleToOverlay() -> CGRect {
            let current: CGRect
            if toggleHost.superview === self {
                current = toggleHost.layer?.presentation()?.frame ?? toggleHost.frame
            } else {
                current = toggleHost.convert(toggleHost.bounds, to: self)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            toggleHost.layer?.removeAnimation(forKey: Self.toggleMotionKey)
            if toggleHost.superview !== self { addSubview(toggleHost) }
            toggleHost.autoresizingMask = []
            toggleHost.frame = current
            CATransaction.commit()
            return current
        }

        private func animateToggle(from start: CGRect, to origin: CGPoint) {
            // NSView's animator can reuse a presentation position from the old
            // parent (e.g. -6 inside the toolbar slot). Supply the start in the
            // overlay's coordinate space explicitly, including mid-flight reversal.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            toggleHost.setFrameOrigin(origin)
            if let layer = toggleHost.layer {
                let motion = CABasicAnimation(keyPath: "position")
                motion.fromValue = NSValue(point: CGPoint(
                    x: start.minX + start.width * layer.anchorPoint.x,
                    y: start.minY + start.height * layer.anchorPoint.y))
                motion.toValue = NSValue(point: layer.position)
                motion.duration = 0.3
                motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(motion, forKey: Self.toggleMotionKey)
            }
            CATransaction.commit()
        }

        func configure(width: CGFloat, presented: Bool, animated: Bool) {
            let changed = self.presented != presented
            let resized = paneWidth != width
            self.paneWidth = width
            self.presented = presented
            host.setAccessibilityHidden(!presented)
            let size = CGSize(width: width, height: bounds.height)
            if host.frame.size != size { host.setFrameSize(size) }
            let origin = CGPoint(x: presented ? bounds.width - width : bounds.width, y: 0)
            if changed, configured, animated, window != nil {
                transitionGeneration += 1
                let generation = transitionGeneration
                transitioning = true
                let start = moveToggleToOverlay()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    host.animator().setFrameOrigin(origin)
                    animateToggle(from: start, to: toggleOrigin)
                } completionHandler: { [weak self] in
                    guard let self, self.transitionGeneration == generation else { return }
                    self.transitioning = false
                    self.dockToggleIfClosed()
                }
            } else if !configured || resized || changed {
                if changed { transitionGeneration += 1; transitioning = false }
                host.setFrameOrigin(origin)
                if presented { moveToggleToOverlay() }
                if !transitioning { toggleHost.layer?.removeAnimation(forKey: Self.toggleMotionKey) }
                if toggleHost.superview === self { toggleHost.setFrameOrigin(toggleOrigin) }
            }
            configured = true
            dockToggleIfClosed()
        }
        override func layout() {
            super.layout()
            guard previousSize != bounds.size else { return }
            previousSize = bounds.size
            host.frame = CGRect(x: presented ? bounds.width - paneWidth : bounds.width,
                                y: 0, width: paneWidth, height: bounds.height)
            if toggleHost.superview === self { toggleHost.setFrameOrigin(toggleOrigin) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            if toggleVisible && toggleHost.superview === self && toggleHost.frame.contains(local) { return super.hitTest(point) }
            guard presented, host.frame.contains(local) else { return nil }
            return super.hitTest(point)
        }
    }
}

struct SettingsInspectorHeader<Details: View>: View {
    @Environment(\.inspectorHasDockedControl) private var dockedControl
    let centerY: CGFloat
    let closeLabel: String
    let close: () -> Void
    @ViewBuilder var details: Details
    var body: some View {
        HStack(spacing: 10) {
            if dockedControl {
                Color.clear.frame(width: 36, height: 36)
            } else {
            SettingsClickOnlyIconButton(symbolName: "arrow.right", label: closeLabel,
                isEnabled: true, action: close)
                .frame(width: 36, height: 36)
                .modifier(ProfileInspectorCloseSurface())
            }
            details.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 36)
        .padding(.horizontal, 16)
        .padding(.top, max(0, centerY - 18))
        .padding(.bottom, 8)
    }
}

struct SettingsInspectorCenterKey: EnvironmentKey {
    static let defaultValue: CGFloat = 28
}
private struct InspectorDockedControlKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var inspectorHasDockedControl: Bool {
        get { self[InspectorDockedControlKey.self] }
        set { self[InspectorDockedControlKey.self] = newValue }
    }
    var settingsInspectorCenterY: CGFloat {
        get { self[SettingsInspectorCenterKey.self] }
        set { self[SettingsInspectorCenterKey.self] = newValue }
    }
}

struct SettingsChromeMetricsKey: PreferenceKey {
    static let defaultValue = SettingsWindowChromeMetrics()
    static func reduce(value: inout SettingsWindowChromeMetrics,
                       nextValue: () -> SettingsWindowChromeMetrics) { value = nextValue() }
}
