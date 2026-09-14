import AVFoundation
import Combine
import CoreBluetooth
import SwiftUI

struct HushTypeSettingsRootView: View {
    @ObservedObject var model: HushTypeSettingsModel
    @ObservedObject private var profiles = ProcessingProfileStore.shared
    @State private var historySearchText = ""
    @State private var inspectorWidth: CGFloat = 420
    @State private var inspectorTitleX: CGFloat = 280
    @State private var inspectorChrome = SettingsWindowChromeMetrics()
    @State private var lastInspectorWasDictionary = false
    @StateObject private var inspectorDockAnchor = SettingsInspectorDockAnchor()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sections: [HushTypeSettingsSection] {
        model.visibleSections
    }

    var body: some View {
        SettingsWindowShell(
            toggleLabel: L10n.string("settings.sidebar.toggle", fallback: "Toggle Sidebar"),
            expandedLabel: L10n.string("settings.sidebar.expanded", fallback: "Expanded"),
            collapsedLabel: L10n.string("settings.sidebar.collapsed", fallback: "Collapsed"),
            stabilizesDetailWidth: false,
            showsSearch: model.selection == .history
        ) {
            detail
                .id(model.selection)
        } sidebar: {
            sidebar
        } header: {
            header
        }
        .coordinateSpace(name: "settingsChrome")
        .onPreferenceChange(SettingsTitleLeadingKey.self) { value in
            if value > 0 { inspectorTitleX = value }
        }
        .onPreferenceChange(SettingsChromeMetricsKey.self) { inspectorChrome = $0 }
        .overlay {
            GeometryReader { geometry in
                let maximum = max(0, geometry.size.width - inspectorTitleX)
                let width = min(maximum, max(min(320, maximum), inspectorWidth))
                let dictionary = model.isDictionaryInspectorPresented ||
                    (!model.isProfileInspectorPresented && lastInspectorWasDictionary)
                SettingsInspectorPresentation(
                    isPresented: model.isProfileInspectorPresented || model.isDictionaryInspectorPresented,
                    width: width, reduceMotion: reduceMotion,
                    showsToggle: true,
                    headerCenterY: inspectorChrome.titlebarCenterY,
                    rightInset: SettingsToolbarGeometry.edgeGap(centerY: inspectorChrome.titlebarCenterY),
                    toggle: toggleInspector,
                    dockAnchor: inspectorDockAnchor
                ) {
                    SettingsInspectorContainer(maximumWidth: maximum, width: $inspectorWidth) {
                        if dictionary {
                            SettingsDictionaryInspector(model: model,
                                onClose: { model.isDictionaryInspectorPresented = false })
                        } else {
                            SettingsProfileInspector(model: model,
                                onClose: { model.isProfileInspectorPresented = false })
                        }
                    }
                    .environment(\.settingsInspectorCenterY, inspectorChrome.titlebarCenterY)
                    .environment(\.inspectorHasDockedControl, true)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .onChange(of: model.isDictionaryInspectorPresented) { _, open in
            if open { lastInspectorWasDictionary = true }
        }
        .onChange(of: model.isProfileInspectorPresented) { _, open in
            if open { lastInspectorWasDictionary = false }
        }
        .modifier(SettingsToolbarChrome())
        .onAppear { model.refresh() }
        .onChange(of: model.selection) { _, _ in historySearchText = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            SettingsNavigationButtons(
                backDisabled: !model.canNavigateBack, forwardDisabled: !model.canNavigateForward,
                backLabel: L10n.string("settings.navigation.back", fallback: "Back"),
                forwardLabel: L10n.string("settings.navigation.forward", fallback: "Forward"),
                back: navigateBack, forward: navigateForward
            )
            Text(model.selection.title)
                .font(.headline)
                .lineLimit(1)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: SettingsTitleLeadingKey.self,
                                           value: geometry.frame(in: .named("settingsChrome")).minX)
                })
            Spacer(minLength: 12)
            SettingsInspectorToolbarControls(anchor: inspectorDockAnchor,
                showsSearch: model.selection == .history, searchText: $historySearchText,
                searchPrompt: L10n.string("settings.history.search", fallback: "Search recognition text"))
        }
    }

    private func toggleInspector() {
        if model.isDictionaryInspectorPresented {
            model.isDictionaryInspectorPresented = false
        } else if model.isProfileInspectorPresented {
            if ProfileEditorPreferences.autosaveEnabled, profiles.isDirty, !profiles.save() { return }
            model.isProfileInspectorPresented = false
        } else if lastInspectorWasDictionary, model.dictionaryLibraryEditors.selectedID != nil {
            model.isDictionaryInspectorPresented = true
        } else if profiles.draft != nil {
            model.isProfileInspectorPresented = true
        } else if let initial = profiles.selected(model.selection == .captions ? .captions : .dictation) ?? profiles.profiles.first {
            model.openProfileInspector(initial)
        } else {
            model.selection = .profiles
        }
    }

    private var sidebar: some View {
        SettingsDrawnSidebar(sections: sections, selection: $model.selection)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .overview: SettingsOverviewView(model: model)
        case .dictation: SettingsDictationView(model: model)
        case .captions: SettingsCaptionsView(model: model)
        case .profiles: SettingsProfilesView(model: model)
        case .shortcuts: SettingsShortcutsView(model: model)
        case .history: SettingsHistoryView(model: model, searchText: $historySearchText)
        case .model: SettingsModelView(model: model)
        case .dictionary: SettingsDictionaryView(model: model)
        case .permissions: SettingsPermissionsView(model: model)
        case .general: SettingsGeneralView(model: model)
        }
    }

    private func navigateBack() {
        model.navigateBack()
    }

    private func navigateForward() {
        model.navigateForward()
    }
}

private struct SettingsTitleLeadingKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private enum RecognitionHistoryFilter: String, CaseIterable, Identifiable {
    case all
    case today
    case sevenDays
    case thirtyDays
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.string("settings.history.filter.all", fallback: "All")
        case .today: L10n.string("settings.history.filter.today", fallback: "Today")
        case .sevenDays: L10n.string("settings.history.filter.seven_days", fallback: "7 Days")
        case .thirtyDays: L10n.string("settings.history.filter.thirty_days", fallback: "30 Days")
        case .custom: L10n.string("settings.history.filter.custom_range", fallback: "Custom")
        }
    }
}

private enum RecognitionHistoryContentFilter: String, CaseIterable, Identifiable {
    case all
    case dictation
    case caption

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.string("settings.history.type.all", fallback: "All")
        case .dictation: L10n.string("settings.history.type.dictation", fallback: "Dictation")
        case .caption: L10n.string("settings.history.type.caption", fallback: "Captions")
        }
    }

    var historyKind: RecognitionHistoryKind? {
        switch self {
        case .all: nil
        case .dictation: .dictation
        case .caption: .caption
        }
    }
}

private struct RecognitionHistoryDayGroup: Identifiable {
    let day: Date
    let entries: [RecognitionHistoryEntry]
    var id: Date { day }
}

private struct SettingsHistoryView: View {
    @ObservedObject var model: HushTypeSettingsModel
    @ObservedObject private var store: RecognitionHistoryStore
    @Environment(\.settingsTopBarHeight) private var topBarHeight
    @Environment(\.settingsSidebarIsResizing) private var sidebarIsResizing
    @Binding var searchText: String
    @AppStorage(RecognitionHistoryPreferences.savingEnabledKey) private var isSavingHistory = true
    @State private var filter: RecognitionHistoryFilter = .all
    @State private var contentFilter: RecognitionHistoryContentFilter = .all
    @State private var customStartDate = Calendar.current.startOfDay(for: Date())
    @State private var customEndDate = Calendar.current.startOfDay(for: Date())
    @State private var entryPendingDeletion: RecognitionHistoryEntry?
    @State private var isConfirmingClear = false
    @State private var displayedGroups: [RecognitionHistoryDayGroup] = []
    @State private var entryNumbers: [UUID: Int] = [:]
    @State private var expandedEntryIDs: Set<UUID> = []

    init(model: HushTypeSettingsModel, searchText: Binding<String>) {
        self.model = model
        _searchText = searchText
        _store = ObservedObject(wrappedValue: model.recognitionHistory)
    }

    var body: some View {
        SettingsNativeHistoryList(
            header: AnyView(historyControls),
            rows: nativeRows,
            topInset: topBarHeight,
            sidebarIsResizing: sidebarIsResizing,
            onDelete: { entryPendingDeletion = $0 },
            onToggleExpansion: toggleExpansion
        )
        .focusSection()
        .accessibilityElement(children: .contain)
        .onReceive(store.$entries) { entries in rebuildHistoryPresentation(entries) }
        .onChange(of: searchText) { _, _ in rebuildHistoryPresentation(store.entries) }
        .onChange(of: filter) { _, _ in rebuildHistoryPresentation(store.entries) }
        .onChange(of: contentFilter) { _, _ in rebuildHistoryPresentation(store.entries) }
        .onChange(of: customStartDate) { _, _ in rebuildHistoryPresentation(store.entries) }
        .onChange(of: customEndDate) { _, _ in rebuildHistoryPresentation(store.entries) }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            rebuildHistoryPresentation(store.entries)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            rebuildHistoryPresentation(store.entries)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            rebuildHistoryPresentation(store.entries)
        }
        .alert(
            L10n.string("settings.history.delete.confirm_title", fallback: "Delete This Entry?"),
            isPresented: Binding(
                get: { entryPendingDeletion != nil },
                set: { if !$0 { entryPendingDeletion = nil } }
            )
        ) {
            Button(L10n.string("common.button.cancel", fallback: "Cancel"), role: .cancel) {
                entryPendingDeletion = nil
            }
            Button(L10n.string("settings.history.delete", fallback: "Delete"), role: .destructive) {
                guard let entry = entryPendingDeletion else { return }
                model.removeRecognitionHistory(id: entry.id)
                entryPendingDeletion = nil
            }
        } message: {
            Text(L10n.string("settings.history.delete.confirm_message", fallback: "This recognition entry will be permanently deleted."))
        }
        .alert(
            L10n.string("settings.history.clear.confirm_title", fallback: "Clear All History?"),
            isPresented: $isConfirmingClear
        ) {
            Button(L10n.string("common.button.cancel", fallback: "Cancel"), role: .cancel) {}
            Button(L10n.string("settings.history.clear", fallback: "Clear All History"), role: .destructive) {
                model.clearRecognitionHistory()
            }
        } message: {
            Text(L10n.string("settings.history.clear.confirm_message", fallback: "All recognition entries will be permanently deleted. This cannot be undone."))
        }
    }

    /// Keep an entry's number stable while filtering: the newest item shows
    /// the current total, then numbers descend through the complete history.
    private var historyControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsPageDescription(
                L10n.string(
                    "settings.history.subtitle",
                    fallback: "Find and copy past recognition results, even when insertion into another app failed."
                )
            )
            .padding(.horizontal, 14)

            SettingsHistoryCard {
                Picker(L10n.string("settings.history.filter", fallback: "Time Range"), selection: $filter) {
                    ForEach(RecognitionHistoryFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }

            if filter == .custom {
                SettingsHistoryCard {
                    DatePicker(
                        L10n.string("settings.history.date_range.start", fallback: "From"),
                        selection: $customStartDate,
                        displayedComponents: .date
                    )
                    DatePicker(
                        L10n.string("settings.history.date_range.end", fallback: "To"),
                        selection: $customEndDate,
                        displayedComponents: .date
                    )
                    Text(L10n.string(
                        "settings.history.date_range.help",
                        fallback: "Includes both selected local calendar days."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            SettingsHistoryCard {
                Picker(
                    L10n.string("settings.history.type_filter", fallback: "Type"),
                    selection: $contentFilter
                ) {
                    ForEach(RecognitionHistoryContentFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }

            if let errorMessage = model.historyErrorMessage {
                SettingsHistoryCard {
                    Label(L10n.string("settings.history.error", fallback: "History couldn’t be updated"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(L10n.string("settings.history.error.dismiss", fallback: "Dismiss")) {
                        model.dismissRecognitionHistoryError()
                    }
                }
            }

            SettingsHistoryCard {
                Toggle(
                    L10n.string("settings.history.saving.enabled", fallback: "Save recognition history"),
                    isOn: $isSavingHistory
                )
                Text(L10n.string(
                    "settings.history.saving.help",
                    fallback: "When off, new dictation and caption sessions are not saved. Existing history stays available."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)

                SettingsFeatureGroup(
                    title: L10n.string("settings.history.storage", fallback: "Storage"),
                    systemImage: "archivebox"
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(L10n.string("settings.history.maximum_entries", fallback: "Maximum entries"), selection: $model.historyMaximumEntries) {
                            Text("100").tag(100)
                            Text("500").tag(500)
                            Text("1,000").tag(1000)
                        }
                        Picker(L10n.string("settings.history.retention", fallback: "Keep history"), selection: $model.historyRetentionDays) {
                            Text(L10n.string("settings.history.retention.seven_days", fallback: "7 days")).tag(7)
                            Text(L10n.string("settings.history.retention.thirty_days", fallback: "30 days")).tag(30)
                            Text(L10n.string("settings.history.retention.ninety_days", fallback: "90 days")).tag(90)
                            Text(L10n.string("settings.history.retention.forever", fallback: "No time limit")).tag(0)
                        }
                        Button(L10n.string("settings.history.clear", fallback: "Clear All History"), role: .destructive) {
                            isConfirmingClear = true
                        }
                        .disabled(store.entries.isEmpty)

                        Text(L10n.string(
                            "settings.history.retention_help",
                            fallback: "Items are permanently removed when either limit is reached. Changing a limit applies immediately."
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if displayedGroups.isEmpty {
                SettingsHistoryCard {
                    ContentUnavailableView {
                        Label(
                            searchText.isEmpty
                                ? L10n.string("settings.history.empty", fallback: "No Recognition History")
                                : L10n.string("settings.history.no_results", fallback: "No Matching Results"),
                            systemImage: searchText.isEmpty ? "clock" : "magnifyingglass"
                        )
                    } description: {
                        Text(searchText.isEmpty
                             ? L10n.string("settings.history.empty_detail", fallback: "New dictation results will appear here before HushType attempts to insert them.")
                             : L10n.string("settings.history.no_results_detail", fallback: "Try another search or time range."))
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                }
            }
        }
        .frame(maxWidth: 736, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 16)
        .padding(.bottom, nativeRows.isEmpty ? 18 : 12)
    }

    private var nativeRows: [SettingsNativeHistoryList.Row] {
        displayedGroups.flatMap { group in
            let groupID = String(group.day.timeIntervalSinceReferenceDate)
            return [SettingsNativeHistoryList.Row.dayHeader(id: groupID, title: dayTitle(group.day))]
                + group.entries.enumerated().map { index, entry in
                    SettingsNativeHistoryList.Row.entry(
                        entry,
                        number: entryNumbers[entry.id, default: 0],
                        time: timeTitle(entry.createdAt),
                        isFirstInDay: index == 0,
                        isLastInDay: index == group.entries.count - 1,
                        isExpanded: expandedEntryIDs.contains(entry.id)
                    )
                }
        }
    }

    // Search, grouping and numbering depend on data, not on the animated
    // detail width. Rebuild only when the data/filter/day actually changes.
    private func rebuildHistoryPresentation(_ entries: [RecognitionHistoryEntry]) {
        entryNumbers = Dictionary(uniqueKeysWithValues: entries.enumerated().map {
            ($0.element.id, entries.count - $0.offset)
        })
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let cutoff: Date? = switch filter {
        case .all: nil
        case .today: startOfToday
        case .sevenDays: calendar.date(byAdding: .day, value: -6, to: startOfToday)
        case .thirtyDays: calendar.date(byAdding: .day, value: -29, to: startOfToday)
        case .custom: nil
        }
        let customRange = RecognitionHistoryDateRange(
            startDate: customStartDate,
            endDate: customEndDate
        )

        let filtered = entries.filter { entry in
            let isRecentEnough = cutoff.map { entry.createdAt >= $0 } ?? true
            let isWithinCustomRange = filter != .custom || customRange.contains(entry.createdAt, calendar: calendar)
            let matchesType = contentFilter.historyKind.map { entry.kind == $0 } ?? true
            let matchesSearch = searchText.isEmpty || entry.text.localizedStandardContains(searchText)
            return isRecentEnough && isWithinCustomRange && matchesType && matchesSearch
        }
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.createdAt) }
        displayedGroups = grouped.keys.sorted(by: >).map { day in
            RecognitionHistoryDayGroup(
                day: day,
                entries: grouped[day, default: []].sorted { $0.createdAt > $1.createdAt }
            )
        }
    }

    private func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return L10n.string("settings.history.day.today", fallback: "Today")
        }
        if calendar.isDateInYesterday(date) {
            return L10n.string("settings.history.day.yesterday", fallback: "Yesterday")
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        return date.formatted(sameYear
                              ? .dateTime.month().day().weekday()
                              : .dateTime.year().month().day().weekday())
    }

    private func timeTitle(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func toggleExpansion(_ entry: RecognitionHistoryEntry) {
        if expandedEntryIDs.contains(entry.id) {
            expandedEntryIDs.remove(entry.id)
        } else {
            expandedEntryIDs.insert(entry.id)
        }
    }
}

/// The history page may contain hundreds of variable-height rows. Keep it out
/// of the shared Form host so resizing the settings chrome does not ask Form to
/// lay out every history row. Other settings pages intentionally retain Form.
private struct SettingsHistoryPage<Content: View>: View {
    @Environment(\.settingsTopBarHeight) private var topBarHeight
    @Environment(\.settingsSidebarIsResizing) private var sidebarIsResizing
    @State private var resize = SettingsHistoryResizeState()
    @State private var visibleEntry: UUID?
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            let layoutWidth = resize.layoutWidth(available: geometry.size.width)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    SettingsPageDescription(subtitle)
                        .padding(.horizontal, 14)

                    content
                }
                .frame(maxWidth: 736, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, max(16, (layoutWidth - 736) / 2))
                .padding(.top, topBarHeight)
                .padding(.bottom, 18)
                .frame(width: layoutWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition(id: $visibleEntry)
            .transaction { $0.animation = nil }
            .background(SettingsHistoryLiveResizeObserver { isResizing in
                resize.setWindowResizing(isResizing, width: geometry.size.width)
            })
            .onChange(of: sidebarIsResizing) { _, active in
                resize.setSidebarResizing(active, width: geometry.size.width)
            }
            .focusSection()
            .accessibilityElement(children: .contain)
        }
    }
}

/// Matches the grouped-settings card treatment while allowing the history page
/// to use ScrollView/LazyVStack rather than Form's eager row layout.
private struct SettingsHistoryCard<Content: View>: View {
    let title: String?
    let footer: String?
    @ViewBuilder var content: Content

    init(
        title: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
        }
    }
}

/// Each day remains a grouped card, but its rows are a LazyVStack in the
/// enclosing ScrollView's coordinate space. This is the actual row-level
/// virtualization boundary; do not replace it with a VStack.
private struct SettingsHistoryEntriesCard<Rows: View>: View {
    let title: String
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)

            LazyVStack(alignment: .leading, spacing: 0) {
                rows
            }
            .scrollTargetLayout()
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsPage<Content: View>: View {
    @Environment(\.usesNativeInspectorEdge) private var nativeInspectorEdge
    @Environment(\.nativeInspectorEdgeHidden) private var nativeInspectorEdgeHidden
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            settingsForm
                .scrollEdgeEffectHidden(!nativeInspectorEdge || nativeInspectorEdgeHidden, for: .top)
        } else {
            settingsForm
        }
    }

    private var settingsForm: some View {
        GeometryReader { geometry in
            Form {
                if let subtitle {
                    Section {
                        SettingsPageDescription(subtitle)
                    }
                    .listRowBackground(Color.clear)
                }

                content
            }
            .formStyle(.grouped)
            .settingsDetailScrollInset()
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Derive margins directly; avoid feeding each animated width
            // back through @State and triggering another Form update.
            .contentMargins(.horizontal, max(0, (geometry.size.width - 736) / 2), for: .scrollContent)
            .focusSection()
            .accessibilityElement(children: .contain)
        }
    }
}

struct SettingsPageDescription: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsDescriptionCard: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        // Lists don't render grouped Form sections. Host the very same native
        // Form here instead of approximating its fill, row height and insets.
        // Intrinsic sizing includes the system's section spacing; no hand-set
        // card height or extra padded background is needed.
        Form {
            Section { SettingsPageDescription(text) }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsSection<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Section {
            content
        }
    }
}


private struct SettingsDictationView: View {
    @ObservedObject var model: HushTypeSettingsModel
    @AppStorage("hushtype.input.method") private var inputMethodRaw = TextInsertionConfiguration.Method.clipboard.rawValue
    var body: some View {
        SettingsPage {
            SettingsTaskControlSection(
                taskName: L10n.string("settings.sidebar.dictation", fallback: "Dictation"),
                statusLabel: L10n.string("settings.captions.status", fallback: "Status"),
                status: dictationStatus,
                state: model.dictationTaskState,
                enabled: model.canToggleDictation,
                action: model.toggleDictation
            )
            ProfileSelectionSection(use: .dictation, model: model)
            SettingsSection {
                Picker(
                    L10n.string("settings.general.input_method", fallback: "Text input method"),
                    selection: inputMethodBinding
                ) {
                    Text(L10n.string("settings.input_method.clipboard", fallback: "Temporary clipboard"))
                        .tag(TextInsertionConfiguration.Method.clipboard)
                    Text(L10n.string("settings.input_method.unicode", fallback: "Unicode keyboard input"))
                        .tag(TextInsertionConfiguration.Method.unicode)
                }
                .pickerStyle(.menu)
            }
            Section {
                Toggle(L10n.string("settings.general.floating_overlay", fallback: "Show the floating recording overlay"), isOn: $model.floatingOverlayEnabled)
            }
            SettingsDebugSections(scope: .dictation, model: model)
        }
    }

    private var dictationStatus: String {
        switch model.dictationTaskState {
        case .stopped:
            L10n.string("settings.captions.status.stopped", fallback: "Stopped")
        case .running:
            model.statusTitle
        case .finishing:
            L10n.string("overview.finishing", fallback: "Finishing")
        }
    }
    private var inputMethodBinding: Binding<TextInsertionConfiguration.Method> {
        Binding(
            get: { TextInsertionConfiguration.Method(rawValue: inputMethodRaw) ?? .clipboard },
            set: { inputMethodRaw = $0.rawValue }
        )
    }
}

private struct SettingsModelView: View {
    @ObservedObject var model: HushTypeSettingsModel
    @ObservedObject private var library: LocalModelLibrary
    @State private var pendingDeletion: LocalModelDescriptor?

    init(model: HushTypeSettingsModel) {
        self.model = model
        self.library = model.modelLibrary
    }

    var body: some View {
        SettingsPage(
            subtitle: L10n.string("settings.model.subtitle", fallback: "Install and manage local speech and text models.")
        ) {
            SettingsSection {
                VStack(alignment: .leading, spacing: 14) {
                    Text(model.statusTitle).font(.headline)
                    Text(model.statusDetail).foregroundStyle(.secondary)
                    if case let .loadingDetailed(progress) = model.appState {
                        ProgressView(value: progress.fraction)
                    } else if case let .loading(progress) = model.appState {
                        ProgressView(value: progress)
                    }
                    HStack {
                        switch model.modelControl {
                        case .stopDownload:
                            Button(L10n.string("settings.model.stop", fallback: "Stop Download")) { model.stopModelDownload() }
                        case .unload:
                            Button(L10n.string("settings.model.unload", fallback: "Unload from Memory")) { model.unloadModel() }
                        case .load:
                            Button(L10n.string("settings.model.load", fallback: "Load Model")) { model.loadOrReloadModel() }
                                .buttonStyle(.borderedProminent)
                        case .none:
                            EmptyView()
                        }
                    }
                }
            }

            Section {
                if library.installedModels.isEmpty && model.loadedModelID == nil {
                    Text(L10n.string(
                        "settings.model.no_installed_models",
                        fallback: "No models are installed. Install one from the model library below."
                    ))
                    .foregroundStyle(.secondary)
                } else {
                    Picker(
                        L10n.string("settings.model.select_model", fallback: "Select model"),
                        selection: $model.modelID
                    ) {
                        ForEach(library.installedModels) { descriptor in
                            Text(descriptor.title).tag(descriptor.id)
                        }
                        if let loadedModelID = model.loadedModelID,
                           LocalModelCatalog.descriptor(for: loadedModelID) == nil {
                            Text(loadedModelID).tag(loadedModelID)
                        }
                    }
                }
            } header: {
                Text(L10n.string("settings.model.installed_picker", fallback: "Installed models"))
            } footer: {
                Text(L10n.string(
                    "settings.model.apply_next_load",
                    fallback: "Model changes take effect the next time it loads."
                ))
            }

            Section {
                ForEach(LocalModelCatalog.models) { descriptor in
                    modelLibraryRow(descriptor)
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("settings.model.library.title", fallback: "Model Library"))
                        .font(.headline)
                    Text(L10n.string(
                        "settings.model.library.subtitle",
                        fallback: "Install models before selecting them. Downloads continue if this window is closed."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                }
            }
            SettingsLocalTextModelView(model: model)
        }
        .onAppear { ensureInstalledSelection() }
        .onChange(of: library.installedModels.map(\.id)) { _, _ in
            ensureInstalledSelection()
        }
        .alert(
            L10n.string("settings.model.delete.confirm_title", fallback: "Delete This Model?"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button(L10n.string("common.button.cancel", fallback: "Cancel"), role: .cancel) {
                pendingDeletion = nil
            }
            Button(L10n.string("settings.model.delete", fallback: "Delete"), role: .destructive) {
                guard let descriptor = pendingDeletion else { return }
                library.delete(descriptor, loadedModelID: model.loadedModelID)
                pendingDeletion = nil
            }
        } message: {
            Text(L10n.string(
                "settings.model.delete.confirm_message",
                fallback: "HushType's local model copy will be moved to the Trash. The model currently in use cannot be deleted."
            ))
        }
    }

    @ViewBuilder
    private func modelLibraryRow(_ descriptor: LocalModelDescriptor) -> some View {
        let state = library.state(for: descriptor)
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(descriptor.title).font(.body.weight(.medium))
                Text(descriptor.detail).font(.subheadline).foregroundStyle(.secondary)
                modelInstallStatus(state)
                if case let .downloading(progress) = state {
                    ProgressView(value: progress.fraction)
                        .frame(maxWidth: 360)
                }
            }
            Spacer(minLength: 12)
            modelInstallAction(descriptor, state: state)
        }
    }

    @ViewBuilder
    private func modelInstallStatus(_ state: LocalModelInstallState) -> some View {
        switch state {
        case .notInstalled:
            Label(L10n.string("settings.model.not_installed", fallback: "Not installed"), systemImage: "square.and.arrow.down")
                .foregroundStyle(.secondary)
        case .preparing:
            Label(L10n.string("settings.model.preparing", fallback: "Checking existing model files"), systemImage: "internaldrive")
                .foregroundStyle(.secondary)
        case let .downloading(progress):
            Label(downloadDetail(progress), systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
        case .verifying:
            Label(L10n.string("settings.model.verifying", fallback: "Verifying model"), systemImage: "checkmark.shield")
                .foregroundStyle(.secondary)
        case .installed:
            Label(L10n.string("settings.model.installed", fallback: "Installed"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .deleting:
            Label(L10n.string("settings.model.deleting", fallback: "Moving to Trash…"), systemImage: "trash")
                .foregroundStyle(.secondary)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func modelInstallAction(_ descriptor: LocalModelDescriptor, state: LocalModelInstallState) -> some View {
        switch state {
        case .notInstalled:
            Button(L10n.string("settings.model.install", fallback: "Install")) {
                library.install(descriptor)
            }
            .buttonStyle(.borderedProminent)
            .disabled(library.activeInstallModelID != nil || library.isEngineLoading)
        case .failed:
            Button(L10n.string("settings.model.reinstall", fallback: "Reinstall")) {
                library.install(descriptor)
            }
            .buttonStyle(.borderedProminent)
            .disabled(library.activeInstallModelID != nil || library.isEngineLoading)
        case .downloading:
            Button(L10n.string("settings.model.stop", fallback: "Stop")) {
                if library.engineLoadingModelID == descriptor.id {
                    model.stopModelDownload()
                } else {
                    library.stopInstall(descriptor)
                }
            }
            .buttonStyle(.bordered)
        case .preparing, .verifying:
            ProgressView().controlSize(.small)
        case .installed:
            if descriptor.id == model.loadedModelID {
                Text(L10n.string("settings.model.in_use", fallback: "In use"))
                    .foregroundStyle(.secondary)
            } else if descriptor.id == library.engineLoadingModelID {
                Text(L10n.string("settings.model.loading", fallback: "Loading"))
                    .foregroundStyle(.secondary)
            } else {
                Button(L10n.string("settings.model.delete", fallback: "Delete"), role: .destructive) {
                    pendingDeletion = descriptor
                }
                .buttonStyle(.bordered)
            }
        case .deleting:
            ProgressView().controlSize(.small)
        }
    }

    private func ensureInstalledSelection() {
        let installedIDs = Set(library.installedModels.map(\.id))
        if installedIDs.contains(model.modelID) { return }
        if let loadedModelID = model.loadedModelID {
            model.modelID = loadedModelID
        } else if let first = library.installedModels.first {
            model.modelID = first.id
        }
    }

    private func downloadDetail(_ progress: ModelLoadProgress) -> String {
        let percent = Int(progress.fraction * 100)
        let downloaded = progress.downloadedBytes.map(formattedBytes) ?? "—"
        let total = progress.totalBytes.map(formattedBytes) ?? "—"
        let speed = progress.bytesPerSecond.map { formattedBytes(Int64($0)) + "/s" } ?? "—"
        let eta = progress.eta.map(formattedDuration) ?? "—"
        return L10n.format(
            "settings.model.download_detail",
            "%1$d%% · %2$@ / %3$@ · %4$@ · %5$@ remaining",
            arguments: [Int32(percent), downloaded, total, speed, eta]
        )
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value >= 3600 { return String(format: "%dh %02dm", value / 3600, (value / 60) % 60) }
        if value >= 60 { return String(format: "%dm %02ds", value / 60, value % 60) }
        return String(value) + "s"
    }
}

private struct SettingsPermissionsView: View {
    @ObservedObject var model: HushTypeSettingsModel

    var body: some View {
        SettingsPage(
            subtitle: L10n.string("settings.permissions.subtitle", fallback: "Manage permissions for global shortcuts, microphone input, and app-audio capture.")
        ) {
            permissionCard(
                icon: "figure.stand",
                title: L10n.string("permission.accessibility.title", fallback: "Accessibility"),
                detail: L10n.string("permission.accessibility.subtitle", fallback: "Required for the global F5 shortcut and inserting text at the cursor."),
                isGranted: model.accessibilityGranted
            ) {
                HStack {
                    Button(L10n.string("common.button.open_system_settings", fallback: "Open System Settings")) {
                        model.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                    Button(L10n.string("permission.accessibility.reset_old", fallback: "Reset Old HushType Entry")) {
                        model.resetOldAccessibilityEntry()
                    }
                    .buttonStyle(.bordered)
                }
                if model.accessibilitySettingsOpened {
                    Label(L10n.string("settings.permissions.accessibility_restart", fallback: "Restart HushType after changing Accessibility; macOS applies this permission to a new process."), systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if model.didResetAccessibility {
                    Label(L10n.string("permission.accessibility.reset_complete", fallback: "Old Accessibility entries cleared. Add or enable HushType again."), systemImage: "checkmark.circle.fill")
                        .font(.subheadline).foregroundStyle(.green)
                }
            }

            permissionCard(
                icon: "mic.fill",
                title: L10n.string("permission.microphone.title", fallback: "Microphone"),
                detail: L10n.string("permission.microphone.subtitle", fallback: "Required to transcribe your voice."),
                isGranted: model.microphoneStatus == .authorized
            ) {
                switch model.microphoneStatus {
                case .authorized:
                    Label(L10n.string("permission.status.allowed", fallback: "Allowed"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .notDetermined:
                    Button(model.isRequestingMicrophone
                           ? L10n.string("permission.status.waiting", fallback: "Waiting…")
                           : L10n.string("permission.microphone.allow", fallback: "Allow Microphone")) {
                        model.requestMicrophone()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRequestingMicrophone)
                case .denied, .restricted:
                    Button(L10n.string("permission.microphone.open_settings", fallback: "Open Microphone Settings")) {
                        model.openMicrophoneSettings()
                    }
                    .buttonStyle(.bordered)
                @unknown default:
                    Button(L10n.string("permission.microphone.open_settings", fallback: "Open Microphone Settings")) {
                        model.openMicrophoneSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }

            permissionCard(
                icon: "record.circle",
                title: L10n.string(
                    "permission.screen_system_audio.name",
                    fallback: "Screen & System Audio Recording"
                ),
                detail: L10n.string(
                    "permission.system_audio.required_by_macos",
                    fallback: "Required by macOS for capturing audio from an application."
                ),
                isGranted: model.systemAudioGranted
            ) {
                if model.systemAudioGranted {
                    Label(
                        L10n.string("permission.status.allowed", fallback: "Allowed"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                } else {
                    HStack {
                        Button(L10n.string(
                            "permission.system_audio.allow",
                            fallback: "Allow System Audio"
                        )) {
                            model.requestSystemAudio()
                        }
                        .buttonStyle(.borderedProminent)
                        Button(L10n.string(
                            "common.button.open_system_settings",
                            fallback: "Open System Settings"
                        )) {
                            model.openSystemAudioSettings()
                        }
                        .buttonStyle(.bordered)
                        if model.didRequestSystemAudio || model.systemAudioSettingsOpened || model.didResetSystemAudio {
                            Button(L10n.string(
                                "onboarding.button.restart",
                                fallback: "Restart HushType"
                            )) {
                                model.restart()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if model.didRequestSystemAudio || model.systemAudioSettingsOpened {
                        Label(L10n.string(
                            "permission.system_audio.restart_guidance",
                            fallback: "After turning on HushType in System Settings, restart the app so macOS applies the permission."
                        ), systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }

                    DisclosureGroup(L10n.string(
                        "permission.troubleshooting.heading",
                        fallback: "Having trouble?"
                    )) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.string(
                                "permission.system_audio.reset_help",
                                fallback: "Use this if HushType is missing or appears twice in System Settings."
                            ))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            Button(L10n.string(
                                "permission.system_audio.reset_stale",
                                fallback: "Reset stale permission entries"
                            )) {
                                model.resetOldSystemAudioEntry()
                            }
                            .buttonStyle(.bordered)
                            if model.didResetSystemAudio {
                                Label(L10n.string(
                                    "permission.system_audio.reset_complete",
                                    fallback: "Reset complete. Turn on HushType in System Settings, then restart."
                                ), systemImage: "checkmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }

            permissionCard(
                icon: "antenna.radiowaves.left.and.right",
                title: L10n.string("permission.bluetooth.title", fallback: "Bluetooth"),
                detail: L10n.string("permission.bluetooth.subtitle", fallback: "Allow in advance to detect disconnections from iPhone and Bluetooth microphones. Not required for the built-in or wired microphone."),
                isGranted: model.bluetoothStatus == .allowedAlways
            ) {
                switch model.bluetoothStatus {
                case .allowedAlways:
                    Label(L10n.string("permission.status.allowed", fallback: "Allowed"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .notDetermined:
                    Button(model.isRequestingBluetooth
                           ? L10n.string("permission.status.waiting", fallback: "Waiting…")
                           : L10n.string("permission.bluetooth.allow", fallback: "Allow Bluetooth")) {
                        model.requestBluetooth()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRequestingBluetooth)
                default:
                    Button(L10n.string("permission.bluetooth.open_settings", fallback: "Open Bluetooth Privacy Settings")) {
                        model.openBluetoothSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if model.needsPermissionRestart {
                SettingsSection {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(L10n.string("settings.permissions.restart_required.title", fallback: "Restart HushType to apply permissions"), systemImage: "arrow.triangle.2.circlepath")
                            .font(.headline)
                        Text(L10n.string("settings.permissions.restart_required.detail", fallback: "Permissions are now allowed. Restart HushType so macOS can apply Accessibility to this app."))
                            .foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button(L10n.string("onboarding.button.restart", fallback: "Restart HushType")) { model.restart() }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                }
            } else if model.onboardingRequired {
                SettingsSection {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(L10n.string("settings.permissions.finish_setup", fallback: "Finish setup to start HushType"), systemImage: "lock.fill")
                            .font(.headline)
                        Text(L10n.string("settings.permissions.onboarding_detail", fallback: "After enabling Accessibility, restart HushType so macOS can apply it. Microphone permission does not require a restart."))
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(L10n.string("onboarding.button.quit", fallback: "Quit")) { model.quit() }
                                .keyboardShortcut(.cancelAction)
                            Spacer()
                            Button(L10n.string("onboarding.button.restart", fallback: "Restart HushType")) { model.restart() }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                                .disabled(!model.accessibilityGranted || model.microphoneStatus == .notDetermined || model.isRequestingMicrophone)
                        }
                    }
                }
            }
        }
    }

    private func permissionCard<Content: View>(
        icon: String,
        title: String,
        detail: String,
        isGranted: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        SettingsSection {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon).font(.title2).foregroundStyle(isGranted ? .green : .orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline)
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(isGranted
                          ? L10n.string("permission.status.allowed", fallback: "Allowed")
                          : L10n.string("permission.status.needs_permission", fallback: "Needs permission"),
                          systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(isGranted ? .green : .orange)
                }
                content()
            }
        }
    }
}

private struct SettingsGeneralView: View {
    @ObservedObject var model: HushTypeSettingsModel
    @AppStorage(OverviewPreferences.developerModeKey) private var developerMode = false

    var body: some View {
        SettingsPage(
            subtitle: L10n.string("settings.general.subtitle", fallback: "Manage the interface, updates, and developer settings.")
        ) {
            SettingsSection {
                Toggle(L10n.string("overview.developer_mode", fallback: "Developer mode"), isOn: $developerMode)
            }

            SettingsSection {
                Picker(selection: $model.interfaceLanguageRaw) {
                    Text(L10n.string("menu.interface_language.follow_system", fallback: "Follow System")).tag(InterfaceLanguage.system.rawValue)
                    Text(L10n.string("menu.interface_language.english", fallback: "English")).tag(InterfaceLanguage.english.rawValue)
                    Text(L10n.string("menu.interface_language.simplified_chinese", fallback: "简体中文")).tag(InterfaceLanguage.simplifiedChinese.rawValue)
                    Text(L10n.string("menu.interface_language.traditional_chinese_taiwan", fallback: "繁體中文（台灣）")).tag(InterfaceLanguage.traditionalChineseTaiwan.rawValue)
                } label: {
                    HStack(spacing: 8) {
                        Text(L10n.string("menu.interface_language", fallback: "Interface Language"))
                        Text(L10n.string("menu.interface_language.applied_next_launch", fallback: "Changes apply next launch"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

            }

            SettingsSection {
                Picker(selection: $model.updateChannelRaw) {
                    Text(L10n.string("settings.general.update_channel.stable", fallback: "Stable"))
                        .tag(UpdateChannel.stable.rawValue)
                    Text(L10n.string("settings.general.update_channel.preview", fallback: "Preview"))
                        .tag(UpdateChannel.preview.rawValue)
                } label: {
                    Text(L10n.string("settings.general.update_channel", fallback: "Updates"))
                }

                Toggle(isOn: $model.silentUpdateRelaunch) {
                    Text(L10n.string("settings.general.silent_update_relaunch", fallback: "Start Silently After Updating"))
                }

                HStack {
                    HStack(spacing: 8) {
                        Button(L10n.string("about.check_updates", fallback: "Check for Updates…")) {
                            model.checkForUpdates()
                        }
                        Text(model.appVersionDisplay)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link(destination: URL(string: "https://github.com/Hanosn2007/HushType")!) {
                        Label("GitHub", systemImage: "arrow.up.right.square")
                    }
                }
            }
            SettingsDebugSections(scope: .general, model: model)
        }
    }

}

extension HushTypeSettingsModel {
    var overviewModelLabel: String {
        if loadedModelID != nil {
            return L10n.string("settings.overview.running_model", fallback: "Running model:")
        }
        switch appState {
        case .loading, .loadingDetailed:
            return L10n.string("settings.overview.loading_model", fallback: "Loading model:")
        default:
            return L10n.string("settings.overview.next_model", fallback: "Next model to load:")
        }
    }

    var overviewModelName: String {
        loadedModelID.map(displayName(for:)) ?? selectedModelName
    }

    var selectedModelName: String {
        displayName(for: modelID)
    }

    var hasPendingModelChange: Bool {
        guard let loadedModelID else { return false }
        return loadedModelID != modelID
    }

    private func displayName(for modelID: String) -> String {
        switch modelID {
        case AppConfig.defaultModelId:
            L10n.string("settings.model.qwen_quality", fallback: "Qwen3-ASR 1.7B 8-bit (quality)")
        case AppConfig.balancedModelId:
            L10n.string("settings.model.balanced", fallback: "Qwen3-ASR 1.7B 4-bit (balanced)")
        case AppConfig.powerSavingModelId:
            L10n.string("settings.model.power_saving", fallback: "Qwen3-ASR 0.6B 4-bit (power saving)")
        default:
            modelID
        }
    }

    var statusTitle: String {
        switch appState {
        case .setupRequired: L10n.string("status.permission_required", fallback: "Permission setup required")
        case .loading: L10n.string("status.loading", fallback: "Loading model")
        case let .loadingDetailed(progress): statusTitle(for: progress)
        case .idle: L10n.string("status.ready", fallback: "Ready")
        case .connecting: L10n.string("status.connecting", fallback: "Connecting microphone")
        case .recording: L10n.string("status.recording", fallback: "Listening")
        case .transcribing: L10n.string("status.transcribing", fallback: "Transcribing")
        case .polishing: L10n.string("status.polishing", fallback: "Polishing text")
        case .error: L10n.string("status.needs_attention", fallback: "Needs attention")
        case .unloaded: L10n.string("status.model_unloaded", fallback: "Model unloaded")
        }
    }

    var statusDetail: String {
        switch appState {
        case .setupRequired:
            L10n.string("settings.status.setup_detail", fallback: "Allow Accessibility and Microphone in Permissions.")
        case .loading:
            L10n.string("settings.status.checking_model", fallback: "Checking the model files already on this Mac.")
        case let .loadingDetailed(progress):
            statusDetail(for: progress)
        case .idle:
            L10n.string("settings.status.ready_detail", fallback: "Press F5 to start dictation.")
        case .connecting:
            L10n.string(
                "settings.status.connecting_detail",
                fallback: "Waiting for microphone audio. Press F5 again to cancel."
            )
        case .recording:
            L10n.string("settings.status.recording_detail", fallback: "Press F5 again when you finish speaking.")
        case .transcribing:
            L10n.string("settings.status.transcribing_detail", fallback: "Turning your voice into text.")
        case .polishing:
            L10n.string("settings.status.polishing_detail", fallback: "Applying your text preferences.")
        case let .error(message): message
        case .unloaded:
            L10n.string("settings.status.unloaded_detail", fallback: "The model remains on this Mac. Load it into memory to start local dictation.")
        }
    }

    var statusSymbol: String {
        switch appState {
        case .setupRequired: "exclamationmark.triangle.fill"
        case .loading, .loadingDetailed: "arrow.down.circle"
        case .idle: "checkmark.circle.fill"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .recording: "mic.circle.fill"
        case .transcribing: "waveform"
        case .polishing: "sparkles"
        case .error: "exclamationmark.circle.fill"
        case .unloaded: "cpu"
        }
    }

    var statusTint: Color {
        switch appState {
        case .idle: .green
        case .recording: .red
        case .error, .setupRequired: .orange
        default: .accentColor
        }
    }

    private func statusTitle(for progress: ModelLoadProgress) -> String {
        switch progress.phase {
        case .checkingLocalModel: L10n.string("settings.model.preparing", fallback: "Checking existing model files")
        case .downloading: L10n.string("settings.model.downloading", fallback: "Downloading model")
        case .verifying: L10n.string("settings.model.verifying", fallback: "Verifying model")
        case .loadingTokenizer: L10n.string("settings.model.loading_tokenizer", fallback: "Loading tokenizer")
        case .loadingAudio: L10n.string("settings.model.loading_audio", fallback: "Loading audio encoder")
        case .loadingText: L10n.string("settings.model.loading_text", fallback: "Loading text decoder")
        case .ready: L10n.string("status.ready", fallback: "Ready")
        }
    }

    private func statusDetail(for progress: ModelLoadProgress) -> String {
        switch progress.phase {
        case .checkingLocalModel:
            return L10n.string("settings.status.checking_model", fallback: "Checking the model files already on this Mac.")
        case .downloading:
            return L10n.format("settings.status.progress", "%1$.0f%% complete", arguments: [progress.fraction * 100])
        case .verifying:
            return L10n.string("settings.status.verifying_model", fallback: "Verifying model files before loading them.")
        case .loadingTokenizer, .loadingAudio, .loadingText:
            return L10n.string("settings.status.loading_model", fallback: "Loading the model into memory.")
        case .ready:
            return L10n.string("settings.status.ready_detail", fallback: "Press F5 to start dictation.")
        }
    }
}
