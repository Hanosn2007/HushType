import AppKit
import Combine
import SwiftUI

/// Keep drafts when changing libraries or navigating to another settings page.
@MainActor
final class DictionaryLibraryEditorSession: ObservableObject {
    @Published var selectedID: UUID?
    private var editors: [UUID: DictionaryEditorModel]

    init(defaultEditor: DictionaryEditorModel) {
        editors = [DictionaryLibraryStore.defaultID: defaultEditor]
    }

    func editor(for id: UUID, fileURL: URL) -> DictionaryEditorModel {
        if let editor = editors[id] { return editor }
        let editor = DictionaryEditorModel(fileURL: fileURL)
        editors[id] = editor
        return editor
    }

    func forget(_ id: UUID) { editors[id] = nil }
}

struct SettingsDictionaryView: View {
    @ObservedObject var model: HushTypeSettingsModel
    @ObservedObject private var session: DictionaryLibraryEditorSession
    @ObservedObject private var store = DictionaryLibraryStore.shared
    @ObservedObject private var profiles = ProcessingProfileStore.shared
    @State private var renaming: DictionaryLibrary?
    @State private var name = ""
    @State private var deleting: DictionaryLibrary?
    @StateObject private var rowCompletion = ProfileRowActionCompletion()

    init(model: HushTypeSettingsModel) {
        self.model = model
        _session = ObservedObject(wrappedValue: model.dictionaryLibraryEditors)
    }

    var body: some View {
        libraryList
        .onDisappear { rowCompletion.cancel() }
        .sheet(isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.string("profiles.rename", fallback: "Rename")).font(.headline)
                TextField(L10n.string("profiles.name", fallback: "Name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                if let error = store.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button(L10n.string("common.button.cancel", fallback: "Cancel")) { renaming = nil }
                        .keyboardShortcut(.cancelAction)
                    Button(L10n.string("profiles.save", fallback: "Save")) {
                        if let renaming, store.rename(id: renaming.id, name: name) {
                            self.renaming = nil
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 360)
        }
        .confirmationDialog(
            L10n.string("dictionary.delete_title", fallback: "Move this library and its rules to Trash?"),
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            )
        ) {
            Button(L10n.string("profiles.delete", fallback: "Delete"), role: .destructive) {
                if let deleting { delete(deleting) }
                deleting = nil
            }
        }
    }

    private var libraryList: some View {
        GeometryReader { geometry in
            List {
                SettingsDescriptionCard(L10n.string(
                    "settings.dictionary.subtitle",
                    fallback: "Manage word libraries that replace recurring recognition mistakes."
                ))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if let error = profiles.errorMessage ?? store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }

                Button(L10n.string("dictionary.new", fallback: "New library"), systemImage: "plus") {
                    if let library = store.create(name: L10n.string("dictionary.new", fallback: "New library")) {
                        renaming = library
                        name = library.name
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 30)

                if store.libraries.isEmpty {
                    Text(L10n.string("overview.none", fallback: "None")).foregroundStyle(.secondary)
                }

                ForEach(store.libraries) { library in
                    Button { model.openDictionaryInspector(id: library.id) } label: {
                        Text(library.name).font(.headline).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                        .padding(.horizontal, 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(L10n.string("profiles.delete", fallback: "Delete")) {
                            rowCompletion.perform(for: library.id) { deleting = library }
                        }
                        .tint(.red)
                        Button(L10n.string("profiles.duplicate", fallback: "Duplicate")) {
                            rowCompletion.perform(for: library.id) { _ = store.duplicate(id: library.id) }
                        }
                        .tint(.blue)
                        Button(L10n.string("profiles.rename", fallback: "Rename")) {
                            rowCompletion.perform(for: library.id) {
                                renaming = library
                                name = library.name
                            }
                        }
                        .tint(.gray)
                    }
                    .contextMenu {
                        Button(L10n.string("profiles.rename", fallback: "Rename")) {
                            renaming = library
                            name = library.name
                        }
                        Button(L10n.string("profiles.duplicate", fallback: "Duplicate")) {
                            _ = store.duplicate(id: library.id)
                        }
                        Button(L10n.string("profiles.delete", fallback: "Delete"), role: .destructive) {
                            deleting = library
                        }
                    }
                }
            }
            .listStyle(.plain)
            .background(ProfileListTableReporter(completion: rowCompletion))
            .scrollContentBackground(.hidden)
            .settingsDetailScrollInset()
            .contentMargins(.horizontal, max(0, (geometry.size.width - 736) / 2), for: .scrollContent)
        }
    }

    private func delete(_ library: DictionaryLibrary) {
        guard profiles.removeDictionaryReference(library.id) else { return }
        guard store.delete(id: library.id) else { return }
        if session.selectedID == library.id {
            session.selectedID = nil
            model.isDictionaryInspectorPresented = false
        }
        session.forget(library.id)
    }

}
