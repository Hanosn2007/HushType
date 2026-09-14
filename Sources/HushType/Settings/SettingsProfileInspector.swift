import AppKit
import SwiftUI

/// A floating editor for the profile selected in `ProcessingProfileStore`.
/// The settings root places this view above the complete window shell so the
/// underlying profile list keeps its position and width.
struct SettingsProfileInspector: View {
    @ObservedObject var model: HushTypeSettingsModel
    let onClose: () -> Void
    @Environment(\.settingsInspectorCenterY) private var headerCenterY

    @ObservedObject private var store = ProcessingProfileStore.shared
    @State private var autosaveTask: Task<Void, Never>?
    @State private var isAutosavePending = false
    @AppStorage(ProfileEditorPreferences.autosaveKey) private var autosave = true

    var body: some View {
        panel
            .onAppear { scheduleAutosave() }
            .onDisappear {
                autosaveTask?.cancel()
                autosaveTask = nil
                isAutosavePending = false
            }
            .onChange(of: store.draft) { _, _ in scheduleAutosave() }
            .onChange(of: autosave) { _, _ in scheduleAutosave() }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            if let draft = store.draft {
                Form {
                    if let error = store.errorMessage {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }

                    Section {
                        Toggle(L10n.string("profiles.autosave", fallback: "Automatically save"), isOn: $autosave)
                        TextField(
                            L10n.string("profiles.name", fallback: "Name"),
                            text: Binding(
                                get: { store.draft?.name ?? draft.name },
                                set: { store.draft?.name = $0 }
                            )
                        )
                        if !autosave {
                            HStack {
                                Spacer()
                                Button(L10n.string("profiles.save", fallback: "Save")) { _ = saveImmediately() }
                                    .disabled(!store.isDirty)
                            }
                        }
                    } footer: {
                        Text(L10n.string(
                            autosave ? "profiles.save_help" : "profiles.manual_save_help",
                            fallback: "Save changes to apply them to the next task. Running tasks keep their starting configuration."
                        ))
                    }

                    ProfileEditorSections(
                        profile: Binding(
                            get: { store.draft ?? draft },
                            set: { store.draft = $0 }
                        ),
                        model: model
                    )
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .modifier(SettingsInspectorScrollChrome { header })
            }
        }
    }

    private var header: some View {
        SettingsInspectorHeader(centerY: headerCenterY,
            closeLabel: L10n.string("profiles.inspector.close", fallback: "Close configuration editor"),
            close: close) {
            SettingsInspectorTitle(model: model, title: store.draft?.name ?? "") {
                Text(isAutosavePending
                    ? L10n.string("profiles.inspector.saving", fallback: "Saving…")
                    : store.isDirty
                        ? L10n.string("profiles.unsaved", fallback: "Unsaved changes")
                        : L10n.string("profiles.inspector.saved", fallback: "Saved"))
                    .font(.caption).foregroundStyle(store.isDirty ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil

        guard autosave, store.isDirty else {
            isAutosavePending = false
            return
        }

        isAutosavePending = true
        autosaveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            autosaveTask = nil
            _ = saveImmediately()
        }
    }

    private func saveImmediately() -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        isAutosavePending = false
        guard store.isDirty else { return true }
        return store.save()
    }

    private func close() {
        if !autosave || saveImmediately() {
            onClose()
        }
    }
}

struct ProfileInspectorCloseSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.background {
                Color.clear.glassEffect(.regular, in: Circle())
            }
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                }
        }
    }
}
