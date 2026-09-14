import AppKit
import ApplicationServices

enum UnicodeTextInput {
    /// Preserve extended graphemes, including joined emoji. A single grapheme
    /// can exceed the requested batch size and is then sent intact.
    static func chunks(_ text: String, batchSize: Int) -> [[UniChar]] {
        var result: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty && current.count + units.count > max(1, batchSize) {
                result.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    @MainActor static func post(_ units: [UniChar]) -> Bool {
        guard !units.isEmpty else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
        down.flags = []
        up.flags = []
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    @MainActor private static func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Spotlight and similar panels can own keyboard focus while Workspace still
    /// reports the application underneath them as frontmost.
    @MainActor static func focusedApplication() -> NSRunningApplication? {
        guard let element = focusedElement() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    @MainActor static func captureFocusValidator(
        focusedElementProvider: @escaping @MainActor () -> AXUIElement? = { focusedElement() },
        applicationProvider: @escaping @MainActor () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    ) -> @MainActor () -> Bool {
        if let original = focusedElementProvider() {
            return {
                guard let current = focusedElementProvider() else { return false }
                return CFEqual(original, current)
            }
        }
        // Some editable controls accept keyboard input without exposing AX.
        guard let application = applicationProvider() else { return { false } }
        return { applicationProvider()?.processIdentifier == application.processIdentifier }
    }
}
