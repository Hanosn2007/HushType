import AppKit
import Carbon
import Foundation

enum HushTypeShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case dictation
    case captions
    case translation
    case polish

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dictation: L10n.string("shortcuts.action.dictation", fallback: "Dictation")
        case .captions: L10n.string("shortcuts.action.captions", fallback: "Live captions")
        case .translation: L10n.string("shortcuts.action.translation", fallback: "Translate selection")
        case .polish: L10n.string("shortcuts.action.polish", fallback: "Proofread selection")
        }
    }
}

enum HushTypeShortcutTrigger: String, Codable, CaseIterable, Identifiable, Sendable {
    case press
    case hold

    var id: String { rawValue }
    var title: String {
        switch self {
        case .press: L10n.string("shortcuts.trigger.press", fallback: "Press")
        case .hold: L10n.string("shortcuts.trigger.hold", fallback: "Hold")
        }
    }
}

struct HushTypeShortcutModifiers: OptionSet, Codable, Equatable, Sendable {
    let rawValue: UInt64
    static let control = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)
    static let all: Self = [.control, .option, .shift, .command]

    init(rawValue: UInt64) { self.rawValue = rawValue }

    init(eventFlags: CGEventFlags) {
        var value: Self = []
        if eventFlags.contains(.maskControl) { value.insert(.control) }
        if eventFlags.contains(.maskAlternate) { value.insert(.option) }
        if eventFlags.contains(.maskShift) { value.insert(.shift) }
        if eventFlags.contains(.maskCommand) { value.insert(.command) }
        self = value
    }

    init(eventFlags: NSEvent.ModifierFlags) {
        var value: Self = []
        if eventFlags.contains(.control) { value.insert(.control) }
        if eventFlags.contains(.option) { value.insert(.option) }
        if eventFlags.contains(.shift) { value.insert(.shift) }
        if eventFlags.contains(.command) { value.insert(.command) }
        self = value
    }

    var displayText: String {
        (contains(.control) ? "⌃" : "")
            + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "")
            + (contains(.command) ? "⌘" : "")
    }
}

struct HushTypeShortcutBinding: Codable, Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: HushTypeShortcutModifiers
    var trigger: HushTypeShortcutTrigger

    init(keyCode: UInt16, modifiers: HushTypeShortcutModifiers = [], trigger: HushTypeShortcutTrigger = .press) {
        self.keyCode = Self.canonicalKeyCode(keyCode)
        self.modifiers = modifiers
        self.trigger = trigger
    }

    // Apple media-mode keyboards can report the physical microphone/F5 key
    // as 176. The persisted binding describes its ordinary F5 counterpart.
    static func canonicalKeyCode(_ keyCode: UInt16) -> UInt16 { keyCode == 176 ? 96 : keyCode }

    func matches(keyCode: UInt16, modifiers: HushTypeShortcutModifiers) -> Bool {
        Self.canonicalKeyCode(self.keyCode) == Self.canonicalKeyCode(keyCode) && self.modifiers == modifiers
    }

    var displayText: String { modifiers.displayText + HushTypeShortcutKeyName.name(for: keyCode) }

    var isValid: Bool {
        guard keyCode < 128 || keyCode == 176,
              modifiers.subtracting(.all).isEmpty,
              !HushTypeShortcutKeyName.modifierKeyCodes.contains(keyCode) else { return false }
        // Function keys work by themselves. Ordinary characters require a
        // command/control/option modifier so a binding cannot capture typing.
        return HushTypeShortcutKeyName.functionNames[Self.canonicalKeyCode(keyCode)] != nil
            || !modifiers.intersection([.command, .control, .option]).isEmpty
    }
}

struct HushTypeShortcutConfiguration: Codable, Equatable, Sendable {
    var dictation: HushTypeShortcutBinding?
    var captions: HushTypeShortcutBinding?
    var translation: HushTypeShortcutBinding? = nil
    var polish: HushTypeShortcutBinding? = nil

    static let defaults = Self(
        dictation: .init(keyCode: 96, trigger: .press),
        captions: .init(keyCode: 96, trigger: .hold)
    )

    subscript(action: HushTypeShortcutAction) -> HushTypeShortcutBinding? {
        get {
            switch action {
            case .dictation: dictation
            case .captions: captions
            case .translation: translation
            case .polish: polish
            }
        }
        set {
            switch action {
            case .dictation: dictation = newValue
            case .captions: captions = newValue
            case .translation: translation = newValue
            case .polish: polish = newValue
            }
        }
    }

    func validate() throws {
        for action in HushTypeShortcutAction.allCases {
            if let binding = self[action], !binding.isValid { throw HushTypeShortcutError.invalidKey }
        }
        let bindings = HushTypeShortcutAction.allCases.compactMap { self[$0] }
        for (index, binding) in bindings.enumerated() {
            for other in bindings.dropFirst(index + 1) where
                binding.matches(keyCode: other.keyCode, modifiers: other.modifiers)
                && binding.trigger == other.trigger {
                throw HushTypeShortcutError.conflict
            }
        }
    }

    func actions(keyCode: UInt16, modifiers: HushTypeShortcutModifiers) -> [HushTypeShortcutAction] {
        HushTypeShortcutAction.allCases.filter { self[$0]?.matches(keyCode: keyCode, modifiers: modifiers) == true }
    }
}

enum HushTypeShortcutError: LocalizedError {
    case invalidKey
    case conflict

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            L10n.string("shortcuts.error.invalid", fallback: "Use F1–F20, or a key with Command, Option, or Control.")
        case .conflict:
            L10n.string("shortcuts.error.conflict", fallback: "This shortcut and trigger are already assigned to another action.")
        }
    }
}

enum HushTypeShortcutPreferences {
    static let storageKey = "hushtype.keyboardShortcuts.v1"
    static let didChange = Notification.Name("HushTypeKeyboardShortcutsDidChange")
    static let captureDidChange = Notification.Name("HushTypeShortcutCaptureDidChange")

    static func load(defaults: UserDefaults = .standard) -> HushTypeShortcutConfiguration {
        guard let data = defaults.data(forKey: storageKey),
              let configuration = try? JSONDecoder().decode(HushTypeShortcutConfiguration.self, from: data),
              (try? configuration.validate()) != nil else { return .defaults }
        return configuration
    }

    static func save(_ configuration: HushTypeShortcutConfiguration, defaults: UserDefaults = .standard) throws {
        try configuration.validate()
        defaults.set(try JSONEncoder().encode(configuration), forKey: storageKey)
        if defaults === UserDefaults.standard {
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func setCapturing(_ isCapturing: Bool) {
        NotificationCenter.default.post(name: captureDidChange, object: isCapturing)
    }
}

enum HushTypeShortcutKeyName {
    static let functionNames: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    static func name(for rawKeyCode: UInt16) -> String {
        let keyCode = HushTypeShortcutBinding.canonicalKeyCode(rawKeyCode)
        if let function = functionNames[keyCode] { return function }
        let special: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        ]
        if let name = special[keyCode] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(keyCode)"
        }
        let data = unsafeBitCast(rawData, to: CFData.self)
        let layout = unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(
            layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count, &length, &characters
        )
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// Classifies complete physical presses using the binding captured on key-down.
/// Configuration changes and event-tap recovery invalidate queued deliveries.
struct HushTypeShortcutPressRouter {
    struct Delivery: Equatable {
        let action: HushTypeShortcutAction
        let generation: UInt64
    }
    enum Result: Equatable {
        case passThrough
        case consume
        case scheduleHold(token: UInt64)
        case deliver(Delivery)
    }
    private struct Press {
        let token: UInt64
        let passThrough: Bool
        let shortAction: HushTypeShortcutAction?
        let longAction: HushTypeShortcutAction?
        var longFired = false
    }
    private var presses: [UInt16: Press] = [:]
    private var nextToken: UInt64 = 1
    private var generation: UInt64 = 1

    mutating func keyDown(
        keyCode: UInt16, modifiers: HushTypeShortcutModifiers, isRepeat: Bool,
        configuration: HushTypeShortcutConfiguration,
        shouldPassThrough: ([HushTypeShortcutAction]) -> Bool
    ) -> Result {
        if let press = presses[keyCode] { return press.passThrough ? .passThrough : .consume }
        let actions = configuration.actions(keyCode: keyCode, modifiers: modifiers)
        guard !actions.isEmpty else { return .passThrough }
        guard !isRepeat else { return .consume }
        let passThrough = shouldPassThrough(actions)
        let token = nextToken
        nextToken &+= 1
        let shortAction = actions.first { configuration[$0]?.trigger == .press }
        let longAction = actions.first { configuration[$0]?.trigger == .hold }
        presses[keyCode] = Press(token: token, passThrough: passThrough, shortAction: shortAction, longAction: longAction)
        if passThrough { return .passThrough }
        return longAction == nil ? .consume : .scheduleHold(token: token)
    }

    mutating func keyUp(keyCode: UInt16) -> Result {
        guard let press = presses.removeValue(forKey: keyCode) else { return .passThrough }
        guard !press.passThrough else { return .passThrough }
        guard !press.longFired, let action = press.shortAction else { return .consume }
        return .deliver(Delivery(action: action, generation: generation))
    }

    mutating func holdDeadlineFired(token: UInt64) -> Delivery? {
        guard let key = presses.first(where: { $0.value.token == token })?.key,
              var press = presses[key], !press.passThrough, !press.longFired,
              let action = press.longAction else { return nil }
        press.longFired = true
        presses[key] = press
        return Delivery(action: action, generation: generation)
    }

    mutating func cancel() {
        presses.removeAll()
        generation &+= 1
    }

    func shouldDeliver(_ delivery: Delivery) -> Bool { delivery.generation == generation }
}
