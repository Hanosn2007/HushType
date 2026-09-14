import SwiftUI

private struct NativeInspectorEdgeKey: EnvironmentKey { static let defaultValue = false }
private struct NativeInspectorEdgeHiddenKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var nativeInspectorEdgeHidden: Bool {
        get { self[NativeInspectorEdgeHiddenKey.self] }
        set { self[NativeInspectorEdgeHiddenKey.self] = newValue }
    }
    var usesNativeInspectorEdge: Bool {
        get { self[NativeInspectorEdgeKey.self] }
        set { self[NativeInspectorEdgeKey.self] = newValue }
    }
}

enum InspectorEdgeStyle: String, CaseIterable, Identifiable {
    case hard, soft, automatic, none
    var id: String { rawValue }
    static let key = "hushtype.settings.inspector.edgeStyle"
}

struct SettingsInspectorScrollChrome<Header: View>: ViewModifier {
    @AppStorage(InspectorEdgeStyle.key) private var style = InspectorEdgeStyle.hard.rawValue
    @ViewBuilder var header: Header
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .environment(\.usesNativeInspectorEdge, true)
                .environment(\.nativeInspectorEdgeHidden, style == "none")
                .scrollEdgeEffectStyle(style == "soft" ? .soft : style == "automatic" ? .automatic : .hard, for: .top)
                .scrollEdgeEffectHidden(style == "none", for: .top)
                .safeAreaBar(edge: .top, spacing: 0) { header }
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) { header.background(.regularMaterial) }
        }
    }
}

struct SettingsInspectorTitle<Status: View>: View {
    @ObservedObject var model: HushTypeSettingsModel
    let title: String
    @ViewBuilder var status: Status
    @State private var choosing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button { choosing.toggle() } label: {
                HStack(spacing: 6) {
                    Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("inspector.choose", fallback: "Choose configuration"))
            .popover(isPresented: $choosing, arrowEdge: .top) {
                SettingsInspectorChooser(model: model) { choosing = false }
            }
            status
        }
    }
}

struct SettingsInspectorChooser: View {
    @ObservedObject var model: HushTypeSettingsModel
    let finish: () -> Void
    @ObservedObject private var profiles = ProcessingProfileStore.shared
    @ObservedObject private var libraries = DictionaryLibraryStore.shared
    @State private var query = ""
    @State private var filter = "all"
    private func matches(_ name: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || name.localizedStandardContains(text)
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.string("inspector.search", fallback: "Search configurations"), text: $query)
                    .textFieldStyle(.plain)
                Menu {
                    category("all", title: L10n.string("inspector.all", fallback: "All"))
                    category("profiles", title: L10n.string("inspector.profiles", fallback: "Processing configurations"))
                    category("dictionary", title: L10n.string("inspector.dictionaries", fallback: "Word libraries"))
                } label: { Image(systemName: "line.3.horizontal.decrease") }
                .menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L10n.string("inspector.filter", fallback: "Filter"))
            }
            .padding(10).background(.quaternary, in: Capsule())
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if filter != "dictionary" {
                        ForEach(profiles.profiles.filter { matches($0.name) }) { profile in
                            choice(profile.name, symbol: "slider.horizontal.3",
                                selected: !model.isDictionaryInspectorPresented && profiles.draft?.id == profile.id) {
                                model.openProfileInspector(profile)
                                if model.isProfileInspectorPresented && profiles.draft?.id == profile.id { finish() }
                            }
                        }
                    }
                    if filter != "profiles" {
                        ForEach(libraries.libraries.filter { matches($0.name) }) { library in
                            choice(library.name, symbol: "text.book.closed",
                                selected: model.isDictionaryInspectorPresented && model.dictionaryLibraryEditors.selectedID == library.id) {
                                model.openDictionaryInspector(id: library.id)
                                if model.isDictionaryInspectorPresented { finish() }
                            }
                        }
                    }
                    if (filter == "dictionary" || !profiles.profiles.contains { matches($0.name) }) &&
                        (filter == "profiles" || !libraries.libraries.contains { matches($0.name) }) {
                        Text(L10n.string("inspector.no_results", fallback: "No matching configurations"))
                            .foregroundStyle(.secondary).padding(10)
                    }
                }
            }
            if let error = profiles.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .padding(12).frame(width: 320, height: 360)
    }
    private func choice(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
                Text(title).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .padding(10).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func category(_ value: String, title: String) -> some View {
        Toggle(title, isOn: Binding(get: { filter == value }, set: { if $0 { filter = value } }))
    }
}
