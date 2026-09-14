import AppKit
import Combine
import SwiftUI

/// Settings presentation for the two global shortcut actions. The actual
/// event tap observes `HushTypeShortcutPreferences`; this page only records
/// and validates a replacement binding before saving it.
struct SettingsShortcutsView: View {
    @ObservedObject var model: HushTypeSettingsModel
    @AppStorage(OverviewPreferences.developerModeKey) private var developerMode = false
    @State private var configuration = HushTypeShortcutPreferences.load()
    @State private var capturingAction: HushTypeShortcutAction?
    @State private var errorAction: HushTypeShortcutAction?
    @State private var errorMessage: String?

    var body: some View {
        SettingsPage(
            subtitle: L10n.string(
                "settings.shortcuts.subtitle",
                fallback: "Set shortcuts for dictation and live captions."
            )
        ) {
            Section {
                ForEach(HushTypeShortcutAction.allCases) { action in
                    ShortcutActionRow(
                        action: action,
                        binding: configuration[action],
                        isCapturing: capturingAction == action,
                        isDisabledByAnotherCapture: capturingAction != nil && capturingAction != action,
                        errorMessage: errorAction == action ? errorMessage : nil,
                        onBeginCapture: { beginCapture(for: action) },
                        onCapture: { capture($0, for: action) },
                        onCancelCapture: stopCapturing,
                        onTriggerChanged: { updateTrigger($0, for: action) },
                        onClear: { clearBinding(for: action) }
                    )
                }
            }

            Section {
                Toggle(L10n.string("settings.general.release_f5_when_unloaded", fallback: "Return F5 to macOS after unloading the model"), isOn: $model.releaseF5WhenModelUnloaded)
            }

            Section {
                HStack {
                    Button(
                        L10n.string("settings.shortcuts.restore_defaults", fallback: "Restore Defaults")
                    ) {
                        restoreDefaults()
                    }
                    .disabled(capturingAction != nil)

                    Spacer()

                    Text(L10n.string(
                        "settings.shortcuts.hold_duration",
                        fallback: "Hold actions activate after 0.5 seconds."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            if developerMode {
                Section {
                    Toggle(L10n.string("settings.shortcuts.legacy_polish", fallback: "Text polishing for the legacy double-tap gesture"), isOn: $model.textPolishEnabled)
                } header: { SettingsDebugDivider() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: HushTypeShortcutPreferences.didChange)) { _ in
            guard capturingAction == nil else { return }
            configuration = HushTypeShortcutPreferences.load()
        }
        .onDisappear(perform: stopCapturing)
    }

    private func beginCapture(for action: HushTypeShortcutAction) {
        guard capturingAction == nil else { return }
        errorAction = nil
        errorMessage = nil
        capturingAction = action
        HushTypeShortcutPreferences.setCapturing(true)
    }

    private func capture(_ event: NSEvent, for action: HushTypeShortcutAction) {
        guard capturingAction == action else { return }
        let candidate = HushTypeShortcutBinding(
            keyCode: event.keyCode,
            modifiers: HushTypeShortcutModifiers(eventFlags: event.modifierFlags),
            trigger: configuration[action]?.trigger ?? .press
        )
        var updated = configuration
        updated[action] = candidate
        save(updated, for: action, finishCaptureOnSuccess: true)
    }

    private func updateTrigger(_ trigger: HushTypeShortcutTrigger, for action: HushTypeShortcutAction) {
        guard var binding = configuration[action] else { return }
        binding.trigger = trigger
        var updated = configuration
        updated[action] = binding
        save(updated, for: action, finishCaptureOnSuccess: false)
    }

    private func clearBinding(for action: HushTypeShortcutAction) {
        var updated = configuration
        updated[action] = nil
        save(updated, for: action, finishCaptureOnSuccess: false)
    }

    private func restoreDefaults() {
        save(.defaults, for: nil, finishCaptureOnSuccess: false)
    }

    private func save(
        _ updated: HushTypeShortcutConfiguration,
        for action: HushTypeShortcutAction?,
        finishCaptureOnSuccess: Bool
    ) {
        do {
            try HushTypeShortcutPreferences.save(updated)
            configuration = updated
            errorAction = nil
            errorMessage = nil
            if finishCaptureOnSuccess { stopCapturing() }
        } catch {
            errorAction = action
            errorMessage = error.localizedDescription
        }
    }

    private func stopCapturing() {
        capturingAction = nil
        HushTypeShortcutPreferences.setCapturing(false)
    }
}

private struct ShortcutActionRow: View {
    let action: HushTypeShortcutAction
    let binding: HushTypeShortcutBinding?
    let isCapturing: Bool
    let isDisabledByAnotherCapture: Bool
    let errorMessage: String?
    let onBeginCapture: () -> Void
    let onCapture: (NSEvent) -> Void
    let onCancelCapture: () -> Void
    let onTriggerChanged: (HushTypeShortcutTrigger) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(action.title)
                    .frame(minWidth: 112, alignment: .leading)

                HushTypeShortcutRecorder(
                    title: isCapturing
                        ? L10n.string("settings.shortcuts.recording", fallback: "Press shortcut…")
                        : binding?.displayText ?? L10n.string("settings.shortcuts.not_set", fallback: "Not Set"),
                    isCapturing: isCapturing,
                    isDisabled: isDisabledByAnotherCapture,
                    onBeginCapture: onBeginCapture,
                    onCapture: onCapture,
                    onCancelCapture: onCancelCapture
                )
                .frame(width: 156, height: 26)

                Picker(
                    L10n.string("settings.shortcuts.trigger", fallback: "Trigger"),
                    selection: Binding(
                        get: { binding?.trigger ?? .press },
                        set: onTriggerChanged
                    )
                ) {
                    ForEach(HushTypeShortcutTrigger.allCases) { trigger in
                        Text(trigger.title).tag(trigger)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 86)
                .disabled(binding == nil || isCapturing)

                Button(L10n.string("settings.shortcuts.clear", fallback: "Clear")) {
                    onClear()
                }
                .disabled(binding == nil || isCapturing)
            }
            .disabled(isDisabledByAnotherCapture)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A first-responder AppKit field rather than a global monitor. It consumes
/// key equivalents while recording, including Command combinations, before an
/// AppKit menu can invoke the associated command.
struct HushTypeShortcutRecorder: NSViewRepresentable {
    let title: String
    let isCapturing: Bool
    let isDisabled: Bool
    let onBeginCapture: () -> Void
    let onCapture: (NSEvent) -> Void
    let onCancelCapture: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> HushTypeShortcutRecorderButton {
        let button = HushTypeShortcutRecorderButton(title: title, target: context.coordinator, action: #selector(Coordinator.didPressButton))
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.coordinator = context.coordinator
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: HushTypeShortcutRecorderButton, context: Context) {
        context.coordinator.onBeginCapture = onBeginCapture
        context.coordinator.onCapture = onCapture
        context.coordinator.onCancelCapture = onCancelCapture
        button.title = title
        button.isEnabled = !isDisabled || isCapturing
        button.isCapturing = isCapturing

        if isCapturing {
            DispatchQueue.main.async { [weak button] in
                guard let button, button.isCapturing else { return }
                button.window?.makeFirstResponder(button)
            }
        } else if button.window?.firstResponder === button {
            button.window?.makeFirstResponder(nil)
        }
    }

    final class Coordinator: NSObject {
        weak var button: HushTypeShortcutRecorderButton?
        var onBeginCapture: () -> Void = {}
        var onCapture: (NSEvent) -> Void = { _ in }
        var onCancelCapture: () -> Void = {}

        @objc func didPressButton() {
            guard let button else { return }
            if button.isCapturing {
                onCancelCapture()
            } else {
                onBeginCapture()
            }
        }

        func receive(_ event: NSEvent) {
            onCapture(event)
        }

        func cancelCapture() {
            onCancelCapture()
        }
    }
}

final class HushTypeShortcutRecorderButton: NSButton {
    weak var coordinator: HushTypeShortcutRecorder.Coordinator?
    var isCapturing = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isCapturing else {
            super.keyDown(with: event)
            return
        }
        handleCapturedEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCapturing else { return super.performKeyEquivalent(with: event) }
        handleCapturedEvent(event)
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        guard isCapturing else {
            super.cancelOperation(sender)
            return
        }
        coordinator?.cancelCapture()
    }

    override func resignFirstResponder() -> Bool {
        let wasCapturing = isCapturing
        let didResign = super.resignFirstResponder()
        if wasCapturing, didResign {
            coordinator?.cancelCapture()
        }
        return didResign
    }

    private func handleCapturedEvent(_ event: NSEvent) {
        if event.keyCode == 53 {
            coordinator?.cancelCapture()
        } else {
            coordinator?.receive(event)
        }
    }
}
