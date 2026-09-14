import AppKit
import SwiftUI

struct DictionaryRulesEditorView<Header: View>: View {
    @ObservedObject var editor: DictionaryEditorModel
    @ViewBuilder var libraryHeader: () -> Header
    @State private var confirmsReload = false
    @State private var didSave = false
    @FocusState private var focusedField: RuleField?

    private enum RuleField: Hashable {
        case source(UUID)
        case target(UUID)

        var ruleID: UUID {
            switch self {
            case .source(let id), .target(let id): id
            }
        }
    }

    private var sourceLabel: String {
        L10n.string("settings.dictionary.editor.source", fallback: "Recognized text")
    }

    private var targetLabel: String {
        L10n.string("settings.dictionary.editor.target", fallback: "Replace with")
    }

    var body: some View {
        SettingsPage(
            subtitle: L10n.string(
                "settings.dictionary.subtitle",
                fallback: "Manage word libraries that replace recurring recognition mistakes."
            )
        ) {
            libraryHeader()
            Section {
                if editor.rules.isEmpty {
                    Text(L10n.string("settings.dictionary.editor.empty", fallback: "No replacement rules yet. Add a word that is often transcribed incorrectly."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    columnLabels
                    ForEach(editor.rules) { rule in
                        ruleRow(rule)
                    }
                }

                HStack {
                    Button {
                        focusedField = .source(editor.addRule())
                    } label: {
                        Label(L10n.string("settings.dictionary.editor.add", fallback: "Add Rule"), systemImage: "plus")
                    }
                    .accessibilityIdentifier("dictionary.add")
                    Spacer()
                    Button(L10n.string("settings.dictionary.editor.reload", fallback: "Reload")) {
                        if editor.hasChanges {
                            confirmsReload = true
                        } else {
                            editor.reload()
                            didSave = false
                        }
                    }
                    .accessibilityIdentifier("dictionary.reload")
                    Button(L10n.string("settings.dictionary.editor.save", fallback: "Save")) {
                        editor.save()
                        didSave = !editor.hasChanges && editor.errorMessage == nil
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!editor.canSave)
                    .accessibilityIdentifier("dictionary.save")
                }

                if let error = editor.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let validation = editor.validationMessage {
                    Text(validation)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if editor.hasChanges {
                    Text(L10n.string("settings.dictionary.editor.unsaved", fallback: "Unsaved changes"))
                        .foregroundStyle(.yellow)
                } else if didSave {
                    Label(L10n.string("settings.dictionary.editor.saved", fallback: "Saved. Applies to the next task using this library."), systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L10n.string("settings.dictionary.entries", fallback: "Customized Dictionary"))
            } footer: {
                Text(L10n.string("settings.dictionary.editor.help", fallback: "Matching ignores case and prefers longer phrases. Replacements do not cascade. Leave the replacement empty to remove matched text. Save to apply changes."))
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("settings.dictionary.editor.preview_input", fallback: "Test text"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $editor.previewInput)
                        .font(.body)
                        .multilineTextAlignment(.leading)
                        .environment(\.layoutDirection, .leftToRight)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 110)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        }
                        .accessibilityLabel(L10n.string("settings.dictionary.editor.preview_input", fallback: "Test text"))
                        .accessibilityIdentifier("dictionary.preview.input")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("settings.dictionary.editor.preview_result", fallback: "Replacement result"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(editor.previewInput.isEmpty ? "—" : editor.previewOutput)
                        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("dictionary.preview.output")
                }
            } header: {
                Text(L10n.string("settings.dictionary.editor.preview", fallback: "Enter Text to Test Replacements"))
            } footer: {
                Text(L10n.string("settings.dictionary.editor.preview_help", fallback: "Uses the rules currently shown, including unsaved edits. Only dictionary replacement is previewed."))
            }
        }
        .onAppear { editor.refreshIfUnchanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            editor.refreshIfUnchanged()
        }
        .onChange(of: editor.rules) { _, _ in
            if editor.hasChanges { didSave = false }
        }
        .confirmationDialog(
            L10n.string("settings.dictionary.editor.discard_title", fallback: "Discard unsaved changes and reload?"),
            isPresented: $confirmsReload,
            titleVisibility: .visible
        ) {
            Button(L10n.string("settings.dictionary.editor.discard_reload", fallback: "Discard and Reload"), role: .destructive) {
                editor.reload()
                didSave = false
            }
            Button(L10n.string("common.button.cancel", fallback: "Cancel"), role: .cancel) {}
        }
    }

    private var columnLabels: some View {
        HStack(spacing: 10) {
            Text(sourceLabel).frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 14, height: 1)
            Text(targetLabel).frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 24, height: 1)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func ruleRow(_ rule: DictionaryRule) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TextField("", text: editor.textBinding(for: rule, field: \.source))
                .labelsHidden()
                .accessibilityLabel(sourceLabel)
                .frame(maxWidth: .infinity)
                .focused($focusedField, equals: .source(rule.id))
                .accessibilityIdentifier("dictionary.source.\(rule.id)")
            Image(systemName: "arrow.right")
                .frame(width: 14)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField("", text: editor.textBinding(for: rule, field: \.target))
                .labelsHidden()
                .accessibilityLabel(targetLabel)
                .frame(maxWidth: .infinity)
                .focused($focusedField, equals: .target(rule.id))
                .accessibilityIdentifier("dictionary.target.\(rule.id)")
            Button {
                if focusedField?.ruleID == rule.id { focusedField = nil }
                editor.removeRule(id: rule.id)
            } label: {
                Image(systemName: "minus.circle")
                    .frame(width: 24)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L10n.string("settings.dictionary.editor.remove", fallback: "Remove Rule"))
            .accessibilityLabel(L10n.string("settings.dictionary.editor.remove", fallback: "Remove Rule"))
            .accessibilityIdentifier("dictionary.remove.\(rule.id)")
        }
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.leading)
    }
}
