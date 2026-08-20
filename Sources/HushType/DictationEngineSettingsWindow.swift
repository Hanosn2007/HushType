import AppKit
import SwiftUI

/// Non-modal floating `NSWindow` hosting `DictationEngineSettingsView`.
/// Menu-bar apps have no parent window to attach a sheet to, so this is a
/// window (not a sheet). Mirrors the house pattern from
/// `LiveCaptionEngineSettingsWindowController`: single shared instance,
/// autosave-pinned position, activate + center on show.
@MainActor
final class DictationEngineSettingsWindowController: NSWindowController, NSWindowDelegate {

    /// Lazy singleton — created on first menu click.
    static let shared: DictationEngineSettingsWindowController = {
        let controller = DictationEngineSettingsWindowController()
        return controller
    }()

    private var onSwitchEngine: ((AppConfig.DictationEngine) -> Void)?

    private init() {
        let hosting = NSHostingController(rootView: DictationEngineSettingsView { engine in
            DictationEngineSettingsWindowController.shared.onSwitchEngine?(engine)
        })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dictation Engine Settings"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("hushtype.settings.dictationEngine")
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Bring the window to front, activating the app if necessary so the
    /// window can take focus from any frontmost menu-bar invocation.
    func presentAndFocus(onSwitchEngine: @escaping (AppConfig.DictationEngine) -> Void) {
        self.onSwitchEngine = onSwitchEngine
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
