import AppKit
import SwiftUI

/// A regular, resizable settings window for the otherwise menu-bar-first app.
/// AppKit owns the singleton window lifecycle; SwiftUI owns the selected pane
/// and all presentation state through `HushTypeSettingsModel`.
@MainActor
final class HushTypeSettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = HushTypeSettingsWindowController()

    /// These are content dimensions. The matching frame dimensions include
    /// the title bar and are calculated from the actual window below.
    private static let defaultContentSize = NSSize(width: 960, height: 680)
    /// Keep the sidebar usable and detail controls readable without making a
    /// selected page dictate a new window size. This is a lower bound only;
    /// `defaultContentSize` is used solely for a brand-new window.
    private static let minimumContentSize = NSSize(width: 900, height: 560)

    private let model = HushTypeSettingsModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("window.settings.title", fallback: "HushType Settings")
        // Keep a meaningful logical window title while the selected page title
        // is rendered by a SwiftUI toolbar item in the detail column.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("hushtype.settings.main")
        let hosting = NSHostingController(rootView: HushTypeSettingsRootView(model: model))
        // Keep the hosting view's intrinsic layout information, but do not let
        // page-specific SwiftUI minimum/maximum measurements drive the window
        // when the sidebar selection changes. An empty sizing option set is
        // invalid here: this controller is the window's root content view and
        // still needs a usable intrinsic layout.
        hosting.sizingOptions = [.intrinsicContentSize]

        // AppKit ignores NSWindow.minSize/contentMinSize for Auto Layout-backed
        // content. Required constraints on the root hosting view are therefore
        // the authoritative, section-independent lower bound.
        NSLayoutConstraint.activate([
            hosting.view.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumContentSize.width),
            hosting.view.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumContentSize.height),
        ])
        window.contentViewController = hosting

        super.init(window: window)
        window.delegate = self
        clampRestoredFrameIfNeeded(of: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(actions: HushTypeSettingsActions) {
        model.configure(actions: actions)
    }

    func present(section: HushTypeSettingsSection = .overview) {
        model.selection = section
        model.refresh()
        if !model.onboardingRequired {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        if let window {
            clampRestoredFrameIfNeeded(of: window)
        }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func reopen() {
        present(section: model.selection)
    }

    func updateAppState(_ state: StatusBarController.State) {
        model.updateAppState(state)
    }

    /// Used by first-run onboarding. The caller still controls whether normal
    /// startup proceeds; this only makes the Permissions page explain the gate.
    func setOnboardingRequired(_ required: Bool) {
        model.onboardingRequired = required
        if required { model.selection = .permissions }
        model.refresh()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        guard !model.onboardingRequired else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Frame autosave restoration can happen before this controller receives
    /// its delegate. Clamp it explicitly, preserving the saved origin as much
    /// as possible, and repeat on every presentation in case AppKit restores a
    /// stale frame later in the window lifecycle.
    private func clampRestoredFrameIfNeeded(of window: NSWindow) {
        let frame = window.frame
        let contentSize = window.contentRect(forFrameRect: frame).size
        guard contentSize.width < Self.minimumContentSize.width
            || contentSize.height < Self.minimumContentSize.height
        else {
            return
        }

        let minimumFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: Self.minimumContentSize)
        ).size
        let constrainedFrame = NSRect(
            origin: frame.origin,
            size: NSSize(
                width: max(frame.size.width, minimumFrameSize.width),
                height: max(frame.size.height, minimumFrameSize.height)
            )
        )
        window.setFrame(constrainedFrame, display: false)
    }
}
