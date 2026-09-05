import AppKit
import SwiftUI

/// Let SwiftUI create a normal Window scene, rather than embedding its
/// contents in a hand-built NSWindow or a special Settings-scene window.
@available(macOS 26.0, *)
struct HushTypeSceneApplication: App {
    #if SETTINGS_PREVIEW
    @NSApplicationDelegateAdaptor(SettingsPreviewDelegate.self) private var delegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif

    var body: some Scene {
        HushTypeSettingsScene()
    }
}

#if SETTINGS_PREVIEW
/// An isolated build of the real settings scene for visual acceptance. It
/// deliberately does not initialize recording, hotkeys, models or updates.
@MainActor
private final class SettingsPreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = HushTypeSettingsWindowController.shared
        settings.updateAppState(.idle)
        settings.present()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif
