import AppKit
import CoreGraphics
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "insertion")

struct TextInserter {
    enum Failure {
        case postEventAccessDenied
        case insertionFailed

        var message: String {
            switch self {
            case .postEventAccessDenied:
                return L10n.string(
                    "status.insertion_permission_denied",
                    fallback: "macOS blocked automatic paste. The transcription is on the clipboard. Allow HushType in Accessibility, relaunch, and try again."
                )
            case .insertionFailed:
                return L10n.string(
                    "status.insertion_failed",
                    fallback: "HushType couldn't insert the transcription. Try pasting it from the clipboard."
                )
            }
        }
    }

    static func insert(_ text: String) -> Failure? {
        guard !text.isEmpty else {
            print("[TextInserter] Empty text, skipping")
            return .insertionFailed
        }

        let pasteboard = NSPasteboard.general

        // Set transcription text to clipboard. Intentionally NOT saving/restoring
        // the previous clipboard contents — leaving the result on the clipboard
        // lets the user re-paste elsewhere or recover if cursor paste was blocked
        // by the focused app.
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            log.error("Failed to write transcription to the pasteboard")
            return .insertionFailed
        }

        guard CGPreflightPostEventAccess() else {
            log.error("PostEvent access denied; requesting access and leaving transcription on the pasteboard")
            _ = CGRequestPostEventAccess()
            return .postEventAccessDenied
        }

        // Handle CJK input method
        var previousInputSourceID: String?
        if InputSourceManager.isCJKInputSourceActive() {
            previousInputSourceID = InputSourceManager.switchToASCII()
            print("[TextInserter] CJK IM detected, switched to ASCII")
            usleep(100_000) // 100ms
        }

        // Simulate Cmd+V
        guard simulatePaste() else {
            if let previousID = previousInputSourceID {
                InputSourceManager.restore(inputSourceID: previousID)
            }
            return .insertionFailed
        }
        print("[TextInserter] Cmd+V sent")

        // Wait longer for paste to complete
        usleep(500_000) // 500ms

        // Restore input source
        if let previousID = previousInputSourceID {
            InputSourceManager.restore(inputSourceID: previousID)
            print("[TextInserter] Restored input source")
        }

        print("[TextInserter] Insert complete")
        return nil
    }

    private static func simulatePaste() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        // kVK_ANSI_V = 0x09
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            log.error("Failed to create paste CGEvents")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        usleep(50_000) // 50ms between key down and up
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
