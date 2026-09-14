import AppKit
import CoreGraphics
import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "systemAudioPermission")

/// Owns the lazy permission flow for Screen & System Audio Recording.
///
/// API: `SystemAudioPermissionFlow.ensurePermission(then:)`.
///
/// macOS caches Screen Recording permission at process start (same per-process
/// cache barrier as Accessibility). After a change, the unified Permissions
/// page explains that HushType must restart before capture can use the grant.
///
/// Implementation note vs. spec §6.b: the spec described two separate alerts
/// (Alert A "post-grant restart", Alert B "denied — open Settings"), but
/// `CGPreflightScreenCaptureAccess()` returns `false` in both cases until the
/// process is restarted, so we cannot reliably distinguish them.
enum SystemAudioPermissionFlow {

    /// If permission is already granted for this process, calls `onReady`
    /// synchronously. Otherwise opens the shared Permissions page. Restarting
    /// the app picks up a newly granted permission, then this function will
    /// short-circuit on the next attempt.
    @MainActor
    static func ensurePermission(then onReady: @escaping () -> Void) {
        routePermission(then: onReady)
    }

    @MainActor
    static func routePermission(
        then onReady: @escaping () -> Void,
        preflight: () -> Bool = { CGPreflightScreenCaptureAccess() },
        presentPermissions: @MainActor () -> Void = {
            HushTypeSettingsWindowController.shared.present(section: .permissions)
        }
    ) {
        if preflight() {
            log.info("Screen capture permission already granted")
            onReady()
            return
        }

        presentPermissions()
    }

    @MainActor
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Called only from an explicit button on the Permissions page.
    @MainActor
    @discardableResult
    static func requestAccess() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        log.info("Requested screen capture access — preflight=\(granted, privacy: .public) (cached state)")
        return granted
    }

    @MainActor
    @discardableResult
    static func resetStaleScreenCaptureEntries() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ScreenCapture", "com.felix.hushtype"]
        do {
            try task.run()
            task.waitUntilExit()
            log.info("tccutil reset ScreenCapture exit code: \(task.terminationStatus)")
            return task.terminationStatus == 0
        } catch {
            log.error("Failed to run tccutil reset ScreenCapture: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @MainActor
    static func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            log.error("Failed to construct Screen Capture settings URL")
            return
        }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    static func presentPermissions() {
        HushTypeSettingsWindowController.shared.present(section: .permissions)
    }

    /// Mid-session revocation alert (spec §6.c). Called from
    /// `LiveCaptionManager` when `SystemAudioSource.onError` reports the
    /// stream was stopped by the system.
    @MainActor
    static func showRevocationAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "alert.system_audio_revoked.title",
            fallback: "System Audio Capture Stopped"
        )
        alert.informativeText = L10n.string(
            "alert.system_audio_revoked.message",
            fallback: "Screen & System Audio Recording permission was revoked.\n\nOpen Permissions to restore audio capture from applications."
        )
        alert.icon = NSImage(named: "AppIcon")
            ?? NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string(
            "common.button.open_permissions",
            fallback: "Open Permissions"
        ))
        alert.addButton(withTitle: L10n.string("common.button.dismiss", fallback: "Dismiss"))

        if alert.runModal() == .alertFirstButtonReturn {
            presentPermissions()
        }
    }
}
