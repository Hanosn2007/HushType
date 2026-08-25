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
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        // `contentMinSize` alone did not constrain old frame-autosave values
        // reliably. Set both coordinate systems and also clamp restored/user
        // resize frames in the delegate below.
        window.contentMinSize = Self.minimumContentSize
        window.minSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: Self.minimumContentSize)
        ).size
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("hushtype.settings.main")
        window.contentViewController = NSHostingController(rootView: HushTypeSettingsRootView(model: model))

        super.init(window: window)
        window.delegate = self
        enforceMinimumSize(of: window)
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
            enforceMinimumSize(of: window)
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

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minimumFrameSize = minimumFrameSize(for: sender)
        return NSSize(
            width: max(frameSize.width, minimumFrameSize.width),
            height: max(frameSize.height, minimumFrameSize.height)
        )
    }

    func windowWillClose(_ notification: Notification) {
        guard !model.onboardingRequired else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func minimumFrameSize(for window: NSWindow) -> NSSize {
        window.frameRect(
            forContentRect: NSRect(origin: .zero, size: Self.minimumContentSize)
        ).size
    }

    /// Frame autosave restoration can happen before this controller receives
    /// its delegate. Clamp it explicitly, preserving the saved origin as much
    /// as possible, and repeat on every presentation in case AppKit restores a
    /// stale frame later in the window lifecycle.
    private func enforceMinimumSize(of window: NSWindow) {
        let minimumFrameSize = minimumFrameSize(for: window)
        window.contentMinSize = Self.minimumContentSize
        window.minSize = minimumFrameSize

        let frame = window.frame
        guard frame.size.width < minimumFrameSize.width || frame.size.height < minimumFrameSize.height else {
            return
        }

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
