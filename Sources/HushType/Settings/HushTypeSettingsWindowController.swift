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
    fileprivate static let defaultContentSize = NSSize(width: 950, height: 650)
    /// Keep the sidebar usable and detail controls readable without making a
    /// selected page dictate a new window size. This is a lower bound only;
    /// `defaultContentSize` is used solely for a brand-new window.
    fileprivate static let minimumContentSize = NSSize(width: 850, height: 600)

    private let model = HushTypeSettingsModel()
    // macOS 26's scene host owns the entire native window, including the
    // container geometry used by the floating NavigationSplitView sidebar.
    // Keep the legacy NSWindow path for macOS 15.
    private var sceneRepresentation: AnyObject?
    private weak var sceneWindow: NSWindow?
    private var sceneWindowObservers: [NSObjectProtocol] = []

    private init() {
        if #available(macOS 26.0, *) {
            super.init(window: nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("window.settings.title", fallback: "HushType Settings")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
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

    /// Register during applicationWillFinishLaunching, before onboarding or
    /// menu actions can request a window. Suppress automatic scene launch so
    /// the app remains menu-bar-first.
    func registerSceneIfNeeded() {
        guard #available(macOS 26.0, *), sceneRepresentation == nil else { return }
        let representation = NSHostingSceneRepresentation {
            HushTypeSettingsScene(model: model) { [weak self] window in
                self?.attachSceneWindow(window)
            }
        }
        sceneRepresentation = representation
        NSApp.addSceneRepresentation(representation)
    }

    func present(section: HushTypeSettingsSection = .overview) {
        model.selection = section
        model.refresh()
        if !model.onboardingRequired {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 26.0, *) {
            registerSceneIfNeeded()
            if let representation = sceneRepresentation as? NSHostingSceneRepresentation<HushTypeSettingsScene> {
                representation.environment.openSettings()
            }
            sceneWindow?.deminiaturize(nil)
            sceneWindow?.makeKeyAndOrderFront(nil)
            return
        }
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

    private func attachSceneWindow(_ window: NSWindow) {
        guard sceneWindow !== window else { return }
        sceneWindowObservers.forEach(NotificationCenter.default.removeObserver)
        sceneWindowObservers.removeAll()
        sceneWindow = window
        // Do not replace SwiftUI's window delegate or content controller.
        // Observe the same lifecycle events that the legacy delegate handles.
        let center = NotificationCenter.default
        sceneWindowObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.windowDidBecomeKey(notification) }
        })
        sceneWindowObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.windowWillClose(notification) }
        })
        window.setFrameAutosaveName("hushtype.settings.main")
        clampRestoredFrameIfNeeded(of: window)
        model.refresh()
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

@available(macOS 26.0, *)
private struct HushTypeSettingsScene: Scene {
    let model: HushTypeSettingsModel
    let onWindowReady: (NSWindow) -> Void

    var body: some Scene {
        Settings {
            HushTypeSettingsRootView(model: model)
                .frame(
                    minWidth: HushTypeSettingsWindowController.minimumContentSize.width,
                    minHeight: HushTypeSettingsWindowController.minimumContentSize.height
                )
                .background(SettingsSceneWindowReader(onWindowReady: onWindowReady))
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultSize(
            width: HushTypeSettingsWindowController.defaultContentSize.width,
            height: HushTypeSettingsWindowController.defaultContentSize.height
        )
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}

/// Observe the scene-created window without taking over SwiftUI's delegate.
private struct SettingsSceneWindowReader: NSViewRepresentable {
    let onWindowReady: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.onWindowReady = onWindowReady
        return view
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {
        nsView.onWindowReady = onWindowReady
    }

    final class WindowReaderView: NSView {
        var onWindowReady: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.onWindowReady?(window)
            }
        }
    }
}
