import AppKit
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "hotkey")

final class HotkeyManager {
    enum DisableReason: String {
        case timeout
        case userInput
    }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancelledRelease: (() -> Void)?
    /// Fires on Right ⌘ + /. Single keyDown event — caller should treat it
    /// as a toggle (start if off, stop if running). Suppressed from
    /// propagation so the focused editor doesn't see it as a "toggle line
    /// comment" — note we only fire on the *right* command bit, so left
    /// ⌘ + / continues to work for editor comment-toggle as expected.
    var onLiveCaptionToggle: (() -> Void)?
    var onDictationToggle: (() -> Void)?
    var onCaptionToggle: (() -> Void)?
    var onTranslateSelection: (() -> Void)?
    var onPolishSelection: (() -> Void)?
    /// A shared short/hold key is passed through as one physical press when
    /// it contains the dictation action and the unloaded-model policy applies.
    var shouldPassThroughDictationShortcut: (() -> Bool)?
    /// The system can disable an active tap while secure input or the login
    /// session is changing. Recovery must happen outside the tap callback.
    var onTapDisabled: ((DisableReason) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRightOptionDown = false
    private var otherKeyPressedDuringHold = false
    private var shortcutConfiguration = HushTypeShortcutPreferences.load()
    private var shortcutRouter = HushTypeShortcutPressRouter()
    private var holdWorkItems: [UInt16: DispatchWorkItem] = [:]
    private var isCapturingShortcut = false
    private var preferenceObservers: [NSObjectProtocol] = []

    private static let rightOptionKeyCode: Int64 = 61 // kVK_RightOption
    private static let longPressThreshold: TimeInterval = 0.5
    /// kVK_ANSI_Slash — physical "/" key. With Shift held, this is "?".
    private static let slashKeyCode: Int64 = 44
    /// Device-dependent bit for Right Command on macOS CGEventFlags.
    /// The published `CGEventFlags.maskCommand` only encodes "some cmd is
    /// pressed"; left vs right lives in the lower byte of the raw value.
    /// 0x10 = right cmd; 0x08 = left cmd.
    private static let rightCommandFlagBit: UInt64 = 0x10
    private static let leftCommandFlagBit: UInt64 = 0x08

    init() {
        let center = NotificationCenter.default
        preferenceObservers = [
            center.addObserver(forName: HushTypeShortcutPreferences.didChange, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.cancelShortcutPresses()
                self.shortcutConfiguration = HushTypeShortcutPreferences.load()
            },
            center.addObserver(forName: HushTypeShortcutPreferences.captureDidChange, object: nil, queue: .main) { [weak self] notification in
                guard let self else { return }
                self.isCapturingShortcut = notification.object as? Bool ?? false
                self.cancelShortcutPresses()
                self.isRightOptionDown = false
                self.otherKeyPressedDuringHold = false
            },
        ]
    }

    deinit {
        preferenceObservers.forEach(NotificationCenter.default.removeObserver)
        holdWorkItems.values.forEach { $0.cancel() }
    }

    func start() {
        if eventTap != nil || runLoopSource != nil {
            stop()
        }

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
            return manager.handleEvent(proxy: proxy, type: type, event: event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            log.error("Failed to create CGEvent tap. Accessibility permission required.")
            promptAccessibilityPermission()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        shortcutConfiguration = HushTypeShortcutPreferences.load()
        log.info("Hotkey manager started with configured shortcuts")
    }

    func stop() {
        isRightOptionDown = false
        otherKeyPressedDuringHold = false
        cancelShortcutPresses()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        log.info("Hotkey manager stopped")
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Never re-enable an active tap from inside its callback. In
        // particular, user-input disablement can happen while macOS is
        // transitioning through the lock-screen secure-input session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelShortcutPresses()
            let reason: DisableReason = type == .tapDisabledByTimeout ? .timeout : .userInput
            log.error("Event tap disabled by \(reason.rawValue, privacy: .public); scheduling a clean rebuild")
            let recovery = onTapDisabled
            DispatchQueue.main.async {
                recovery?(reason)
            }
            return Unmanaged.passUnretained(event)
        }

        // The recorder is the foreground first responder. Pass through the
        // entire capture gesture rather than invoking the action being edited.
        if isCapturingShortcut { return Unmanaged.passUnretained(event) }

        if type == .keyDown || type == .keyUp {
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let result: HushTypeShortcutPressRouter.Result
            if type == .keyDown {
                result = shortcutRouter.keyDown(
                    keyCode: keyCode,
                    modifiers: .init(eventFlags: event.flags),
                    isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                    configuration: shortcutConfiguration,
                    shouldPassThrough: { [weak self] actions in
                        actions.contains(.dictation) && self?.shouldPassThroughDictationShortcut?() == true
                    }
                )
            } else {
                holdWorkItems.removeValue(forKey: keyCode)?.cancel()
                result = shortcutRouter.keyUp(keyCode: keyCode)
            }
            switch result {
            case .passThrough:
                break
            case .consume:
                if isRightOptionDown { otherKeyPressedDuringHold = true }
                return nil
            case .scheduleHold(let token):
                if isRightOptionDown { otherKeyPressedDuringHold = true }
                scheduleHold(keyCode: keyCode, token: token)
                return nil
            case .deliver(let delivery):
                deliverShortcut(delivery)
                return nil
            }
        }

        // Live Caption toggle: Right ⌘ + /. Single discrete keyDown. We
        // require the Right command bit specifically and forbid the Left
        // command bit so users who comment-toggle with left ⌘ + / in an
        // editor aren't disrupted. Shift is explicitly disallowed too so
        // "left ⌘ + ?" Help-menu and any "right ⌘ + ?" combos route
        // normally — only the bare "right ⌘ + /" combo triggers LC toggle.
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Self.slashKeyCode {
                let flagsRaw = event.flags.rawValue
                let rightCmd = (flagsRaw & Self.rightCommandFlagBit) != 0
                let leftCmd = (flagsRaw & Self.leftCommandFlagBit) != 0
                let shift = event.flags.contains(.maskShift)
                if rightCmd && !leftCmd && !shift,
                   let onLiveCaptionToggle {
                    log.debug("Live Caption hotkey (Right ⌘ + /)")
                    onLiveCaptionToggle()
                    return nil // suppress — don't let editors interpret as comment-toggle
                }
            }
        }

        // Track if other keys are pressed during Right Option hold
        if type == .keyDown && isRightOptionDown {
            otherKeyPressedDuringHold = true
            return Unmanaged.passUnretained(event) // pass through
        }

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Self.rightOptionKeyCode else {
            return Unmanaged.passUnretained(event)
        }
        guard onPress != nil || onRelease != nil || onCancelledRelease != nil else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let optionPressed = flags.contains(.maskAlternate)

        if optionPressed && !isRightOptionDown {
            // Right Option pressed
            isRightOptionDown = true
            otherKeyPressedDuringHold = false
            log.debug("Right Option pressed")
            onPress?()
            return nil // suppress
        } else if !optionPressed && isRightOptionDown {
            // Right Option released
            isRightOptionDown = false
            log.debug("Right Option released (otherKeys: \(self.otherKeyPressedDuringHold))")
            if !otherKeyPressedDuringHold {
                onRelease?()
            } else {
                onCancelledRelease?()
            }
            return nil // suppress
        }

        return Unmanaged.passUnretained(event)
    }

    private func scheduleHold(keyCode: UInt16, token: UInt64) {
        holdWorkItems.removeValue(forKey: keyCode)?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  let delivery = self.shortcutRouter.holdDeadlineFired(token: token) else { return }
            self.holdWorkItems.removeValue(forKey: keyCode)
            self.deliverShortcut(delivery)
        }
        holdWorkItems[keyCode] = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.longPressThreshold,
            execute: work
        )
    }

    private func deliverShortcut(_ delivery: HushTypeShortcutPressRouter.Delivery) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isCapturingShortcut, self.shortcutRouter.shouldDeliver(delivery) else { return }
            switch delivery.action {
            case .dictation: self.onDictationToggle?()
            case .captions: self.onCaptionToggle?()
            case .translation: self.onTranslateSelection?()
            case .polish: self.onPolishSelection?()
            }
        }
    }

    private func cancelShortcutPresses() {
        holdWorkItems.values.forEach { $0.cancel() }
        holdWorkItems.removeAll()
        shortcutRouter.cancel()
    }

    private func promptAccessibilityPermission() {
        // Last-resort fallback. In the normal flow, OnboardingManager.runIfNeeded()
        // catches missing-permission cases at launch BEFORE we ever call
        // CGEvent.tapCreate, so this code path should rarely fire. Reaching it
        // means the user revoked Accessibility while HushType was running, or
        // the kernel returned the cached "denied" state from a pre-grant call.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = L10n.string(
                "alert.accessibility_lost.title",
                fallback: "Accessibility Permission Lost"
            )
            alert.informativeText = L10n.string(
                "alert.accessibility_lost.message",
                fallback: "HushType lost Accessibility permission and the global hotkey is no longer working.\n\nRe-enable HushType in System Settings → Privacy & Security → Accessibility, then quit and relaunch HushType."
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.string(
                "common.button.open_system_settings",
                fallback: "Open System Settings"
            ))
            alert.addButton(withTitle: L10n.string("onboarding.button.quit", fallback: "Quit"))

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                NSWorkspace.shared.open(url)
            } else {
                NSApp.terminate(nil)
            }
        }
    }
}
