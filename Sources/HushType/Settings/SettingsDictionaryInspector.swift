import SwiftUI

/// The content hosted by the shared floating settings inspector. Closing the
/// inspector only hides it; the library session retains each editor's draft.
struct SettingsDictionaryInspector: View {
    @ObservedObject var model: HushTypeSettingsModel
    let onClose: () -> Void
    @Environment(\.settingsInspectorCenterY) private var headerCenterY

    @ObservedObject private var session: DictionaryLibraryEditorSession
    @ObservedObject private var store = DictionaryLibraryStore.shared

    init(model: HushTypeSettingsModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _session = ObservedObject(wrappedValue: model.dictionaryLibraryEditors)
    }

    @ViewBuilder
    var body: some View {
        if let id = session.selectedID,
           let library = store.library(id: id) {
            VStack(spacing: 0) {
                DictionaryRulesEditorView(
                    editor: session.editor(for: id, fileURL: store.fileURL(for: id))
                ) {
                    EmptyView()
                }
                .id(id)
                .environment(\.settingsTopBarHeight, 0)
                .modifier(SettingsInspectorScrollChrome { header(for: library) })
            }
        }
    }

    private func header(for library: DictionaryLibrary) -> some View {
        SettingsInspectorHeader(centerY: headerCenterY,
            closeLabel: L10n.string("dictionary.inspector.close", fallback: "Close word library editor"),
            close: onClose) {
            SettingsInspectorTitle(model: model, title: library.name) { EmptyView() }
        }
    }
}
