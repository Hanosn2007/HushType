import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension ProcessingProfile.Input {
    var displayName: String {
        switch kind {
        case .microphone:
            if device == AudioInputSelection.followSystem { return L10n.string("profiles.follow_system", fallback: "System input device") }
            if device == AudioInputSelection.automatic { return L10n.string("profiles.automatic", fallback: "Automatic input device") }
            return AudioInputDeviceManager.currentDeviceName(rawValue: device)
                ?? L10n.string("profiles.unavailable_device", fallback: "Unavailable input device")
        case .application:
            guard hasCaptureSource else { return L10n.string("overview.none", fallback: "None") }
            return applicationName.isEmpty ? bundleID : applicationName
        }
    }
}

struct SettingsProfilesView: View {
    @ObservedObject var model: HushTypeSettingsModel
    @ObservedObject private var modelLibrary: LocalModelLibrary
    init(model: HushTypeSettingsModel) {
        self.model = model
        self.modelLibrary = model.modelLibrary
    }
    @ObservedObject private var store = ProcessingProfileStore.shared
    @State private var deleting: ProcessingProfile?
    @State private var renaming: ProcessingProfile?
    @State private var editedName = ""
    @State private var blockedDeletion: String?
    @StateObject private var rowCompletion = ProfileRowActionCompletion()

    var body: some View {
        profileList
        .onAppear { modelLibrary.refresh() }
        .onChange(of: store.draft?.id) { _, id in
            model.isProfileInspectorPresented = id != nil
        }
        .onDisappear { rowCompletion.cancel() }
        .confirmationDialog(L10n.string("profiles.delete_title", fallback: "Move this configuration to Trash?"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.string("profiles.delete", fallback: "Delete"), role: .destructive) {
                if let deleting {
                    if isOccupied(deleting.id) { blockedDeletion = usageLabel(deleting.id) }
                    else { store.delete(deleting, additionalInUseIDs: activeIDs) }
                }
                deleting = nil
            }
        }
        .alert(L10n.string("profiles.delete_in_use", fallback: "Configuration in use"),
               isPresented: Binding(get: { blockedDeletion != nil }, set: { if !$0 { blockedDeletion = nil } })) {
            Button(L10n.string("common.button.ok", fallback: "OK")) { blockedDeletion = nil }
        } message: { Text(blockedDeletion ?? "") }
        .sheet(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.string("profiles.rename", fallback: "Rename")).font(.headline)
                TextField(L10n.string("profiles.name", fallback: "Name"), text: $editedName).textFieldStyle(.roundedBorder)
                if let error = store.errorMessage { Text(error).foregroundStyle(.orange).font(.caption) }
                HStack {
                    Spacer()
                    Button(L10n.string("common.button.cancel", fallback: "Cancel")) { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button(L10n.string("profiles.save", fallback: "Save")) {
                        if let renaming, store.rename(profileID: renaming.id, name: editedName) { self.renaming = nil }
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 360)
        }
    }



    private var profileList: some View {
        GeometryReader { geometry in
            List {
                SettingsDescriptionCard(L10n.string(
                    "profiles.subtitle",
                    fallback: "Create reusable configurations for input, recognition, cleanup, and AI processing."
                ))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                HStack {
                    Button(L10n.string("profiles.new", fallback: "New configuration"), systemImage: "plus") {
                        if let profile = store.createSaved(availableLibraryIDs: Set(DictionaryLibraryStore.shared.libraries.map(\.id))) {
                            renaming = profile
                            editedName = profile.name
                        }
                    }
                    Spacer()
                    Button(L10n.string("profiles.import", fallback: "Import"), systemImage: "square.and.arrow.down") { importProfile() }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 30)
                ForEach(store.profiles) { profile in
                    Button {
                        model.openProfileInspector(profile)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(profile.name).font(.headline).foregroundStyle(.primary)
                            if let usage = usageLabel(profile.id) {
                                Text(usage).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(profile.input.displayName + " · " + modelLibrary.profileTitle(profile.modelID, loadedID: model.loadedModelID))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .padding(.horizontal, 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        // This action requests confirmation; the row is not
                        // deleted until the dialog's destructive action runs.
                        Button(L10n.string("profiles.delete", fallback: "Delete")) {
                            rowCompletion.perform(for: profile.id) { requestDeletion(profile) }
                        }
                            .tint(.red)
                            .disabled(isOccupied(profile.id))
                        Button(L10n.string("profiles.duplicate", fallback: "Duplicate")) {
                            rowCompletion.perform(for: profile.id) { _ = store.duplicate(profileID: profile.id) }
                        }
                            .tint(.blue)
                        Button(L10n.string("profiles.rename", fallback: "Rename")) {
                            rowCompletion.perform(for: profile.id) { renaming = profile; editedName = profile.name }
                        }
                            .tint(.gray)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button(L10n.string("profiles.export", fallback: "Export")) {
                            rowCompletion.perform(for: profile.id) { exportProfile(profile) }
                        }
                            .tint(.blue)
                    }
                    .contextMenu {
                        Button(L10n.string("profiles.rename", fallback: "Rename")) { renaming = profile; editedName = profile.name }
                        Button(L10n.string("profiles.duplicate", fallback: "Duplicate")) { _ = store.duplicate(profileID: profile.id) }
                        Button(L10n.string("profiles.export", fallback: "Export")) { exportProfile(profile) }
                        Button(L10n.string("profiles.delete", fallback: "Delete"), role: .destructive) { requestDeletion(profile) }
                            .disabled(isOccupied(profile.id))
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

    private var activeIDs: Set<UUID> {
        Set([model.activeDictationProfile?.id, model.activeCaptionProfile?.id].compactMap { $0 })
    }
    private func isOccupied(_ id: UUID) -> Bool { store.isSelected(id) || activeIDs.contains(id) }
    private func requestDeletion(_ profile: ProcessingProfile) {
        if isOccupied(profile.id) { blockedDeletion = usageLabel(profile.id) }
        else { deleting = profile }
    }
    private func usageLabel(_ id: UUID) -> String? {
        var users: [String] = []
        if store.dictationID == id || model.activeDictationProfile?.id == id {
            users.append(L10n.string("settings.sidebar.dictation", fallback: "Dictation"))
        }
        if store.captionsID == id || model.activeCaptionProfile?.id == id {
            users.append(L10n.string("settings.sidebar.captions", fallback: "Captions"))
        }
        guard !users.isEmpty else { return nil }
        return L10n.format("profiles.used_by", "Used by %1$@", arguments: [users.joined(separator: "、")])
    }
    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            _ = store.importProfile(from: url)
        }
    }
    private func exportProfile(_ profile: ProcessingProfile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.message = L10n.string("profiles.export_help", fallback: "Exports configuration options only. Model and word-library files are not included.")
        panel.nameFieldStringValue = profile.name.replacingOccurrences(of: "/", with: "-") + ".json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            _ = store.exportProfile(id: profile.id, to: url)
        }
    }
}

struct ProfileEditorSections: View {
    @Binding var profile: ProcessingProfile
    @ObservedObject private var libraries = DictionaryLibraryStore.shared
    @ObservedObject var model: HushTypeSettingsModel
    @ObservedObject private var modelLibrary: LocalModelLibrary
    @State private var textModelAvailable = false
    @State private var applications: [NSRunningApplication] = []
    init(profile: Binding<ProcessingProfile>, model: HushTypeSettingsModel) {
        self._profile = profile
        self.model = model
        self.modelLibrary = model.modelLibrary
    }

    var body: some View {
        Section {
            Picker(L10n.string("profiles.source_kind", fallback: "Source"), selection: $profile.input.kind) {
                Text(L10n.string("profiles.microphone", fallback: "Input device")).tag(ProcessingProfile.Input.Kind.microphone)
                Text(L10n.string("profiles.application_audio", fallback: "App audio")).tag(ProcessingProfile.Input.Kind.application)
            }.pickerStyle(.segmented)
            if profile.input.kind == .microphone {
                LabeledContent(L10n.string("profiles.device", fallback: "Device")) {
                    SettingsRefreshingPicker(selection: profile.input.device, selectedTitle: profile.input.displayName,
                        options: {
                            let devices = AudioInputDeviceManager.availableDevices()
                            return [
                                .init(id: AudioInputSelection.followSystem, title: L10n.string("profiles.follow_system", fallback: "System input device")),
                                .init(id: AudioInputSelection.automatic, title: L10n.string("profiles.automatic", fallback: "Automatic input device"))
                            ] + devices.map { .init(id: AudioInputSelection.device($0.id), title: $0.name) }
                        }, changed: { profile.input.device = $0 })
                }
            } else {
                LabeledContent(L10n.string("profiles.choose_application", fallback: "Choose an application")) {
                    SettingsRefreshingPicker(selection: profile.input.bundleID,
                        selectedTitle: profile.input.bundleID.isEmpty ? L10n.string("overview.none", fallback: "None") : profile.input.displayName,
                        options: {
                            refreshSources()
                            return [.init(id: "", title: L10n.string("overview.none", fallback: "None"))]
                                + applications.map { .init(id: $0.bundleIdentifier ?? "", title: $0.localizedName ?? $0.bundleIdentifier ?? "") }
                        }, changed: { id in
                            profile.input.bundleID = id
                            profile.input.applicationName = applications.first { $0.bundleIdentifier == id }?.localizedName ?? id
                        })
                }
            }
        } header: { Text(L10n.string("profiles.group.input", fallback: "1. Input source")) }
        .onAppear { refreshSources(); refreshModels() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshModels() }

        Section {
            Picker(L10n.string("profiles.asr", fallback: "Speech model"), selection: $profile.modelID) {
                ForEach(LocalModelCatalog.models) { item in Text(modelLibrary.profileTitle(item.id, loadedID: model.loadedModelID)).tag(item.id) }
            }
            Picker(L10n.string("profiles.language", fallback: "Recognition language"), selection: $profile.language) {
                Text(L10n.string("menu.choice.auto", fallback: "Auto")).tag("auto")
                Text("中文").tag("chinese"); Text("English").tag("english"); Text("日本語").tag("japanese")
            }
        } header: { Text(L10n.string("profiles.group.recognition", fallback: "2. Recognition")) }

        Section {
            Toggle(L10n.string("settings.general.number_conversion", fallback: "Convert Chinese numbers to digits"), isOn: $profile.rules.numbers)
            Toggle(L10n.string("settings.dictation.traditional_chinese", fallback: "Convert Simplified Chinese output to Traditional Chinese"), isOn: $profile.rules.traditionalChinese)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("dictionary.libraries", fallback: "Word libraries"))
                if libraries.libraries.isEmpty {
                    Text(L10n.string("overview.none", fallback: "None")).foregroundStyle(.secondary)
                }
                ForEach(libraries.libraries) { library in
                    Toggle(library.name, isOn: Binding(
                        get: { profile.rules.dictionaryIDs.contains(library.id) },
                        set: { selected in
                            profile.rules.dictionaryIDs.removeAll { $0 == library.id }
                            if selected { profile.rules.dictionaryIDs.append(library.id) }
                        }
                    )).toggleStyle(.checkbox)
                }
                Text(L10n.string("dictionary.selection_help", fallback: "Select none, one, or several. With none selected, no dictionary replacements are applied."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.string("dictionary.priority_help", fallback: "When sources repeat, the first library in the list wins. Longer matches take priority; replacements do not cascade."))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
            Picker(L10n.string("settings.general.punctuation", fallback: "Punctuation cleanup"), selection: $profile.rules.punctuation) {
                Text(L10n.string("settings.general.punctuation.soft", fallback: "Soft")).tag("soft")
                Text(L10n.string("settings.general.punctuation.hard", fallback: "Strict")).tag("hard")
                Text(L10n.string("settings.general.punctuation.off", fallback: "Off")).tag("off")
            }
            Button(L10n.string("profiles.edit_dictionary", fallback: "Edit dictionary")) { model.selection = .dictionary }
        } header: { Text(L10n.string("profiles.group.rules", fallback: "3. Rule-based cleanup")) }

        Section {
            Toggle(L10n.string("profiles.polish", fallback: "Proofread"), isOn: $profile.llm.polish)
            Picker(L10n.string("profiles.polish_backend", fallback: "Proofreading backend"), selection: $profile.llm.polishBackend) {
                Text(textModelAvailable ? "Qwen3 4B" : "Qwen3 4B " + L10n.string("profiles.unavailable", fallback: "(Unavailable)")).tag("qwen")
            }.disabled(!profile.llm.polish)
            Picker(L10n.string("profiles.correction", fallback: "Correction level"), selection: $profile.llm.correction) {
                ForEach(ProcessingProfile.Correction.allCases, id: \.self) { Text($0.title).tag($0) }
            }.disabled(!profile.llm.polish)
            Toggle(L10n.string("profiles.translate", fallback: "Translate"), isOn: $profile.llm.translate)
            Picker(L10n.string("profiles.translation_backend", fallback: "Translation backend"), selection: $profile.llm.translationBackend) {
                Text(textModelAvailable ? "Qwen3 4B" : "Qwen3 4B " + L10n.string("profiles.unavailable", fallback: "(Unavailable)")).tag("qwen")
            }.disabled(!profile.llm.translate)
            Picker(L10n.string("profiles.target", fallback: "Target language"), selection: $profile.llm.target) {
                ForEach(LocalTextLanguage.allCases) { Text($0.title).tag($0.rawValue) }
            }.disabled(!profile.llm.translate)
        } header: { Text(L10n.string("profiles.group.llm", fallback: "4. LLM processing")) }
        footer: { Text(L10n.string("profiles.llm_help", fallback: "Proofreading runs before translation when both are enabled. Other backends are not yet available.")) }
    }

    private func refreshSources() {
        var seen = Set<String>()
        applications = NSWorkspace.shared.runningApplications.filter {
            guard $0.activationPolicy == .regular, let id = $0.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier else { return false }
            return seen.insert(id).inserted
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func refreshModels() {
        modelLibrary.refresh()
        if let catalog = try? LocalTextModelCatalog(), case .installed = catalog.installation() { textModelAvailable = true }
        else { textModelAvailable = false }
    }
}

struct ProfileSelectionSection: View {
    let use: ProcessingProfileStore.Use
    @ObservedObject var model: HushTypeSettingsModel
    @ObservedObject private var store = ProcessingProfileStore.shared
    @ObservedObject private var modelLibrary: LocalModelLibrary
    init(use: ProcessingProfileStore.Use, model: HushTypeSettingsModel) {
        self.use = use
        self.model = model
        self.modelLibrary = model.modelLibrary
    }

    var body: some View {
        Section {
            Picker(L10n.string("profiles.configuration", fallback: "Configuration"), selection: Binding(
                get: { store.selected(use)?.id }, set: { if let id = $0 { store.select(id, for: use) } })) {
                ForEach(store.profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            if let profile = store.selected(use) {
                LabeledContent(L10n.string("overview.input_sources", fallback: "Input sources"), value: profile.input.displayName)
                LabeledContent(L10n.string("profiles.asr", fallback: "Speech model"), value: modelLibrary.profileTitle(profile.modelID, loadedID: model.loadedModelID))
                Button(L10n.string("profiles.edit", fallback: "Edit configuration")) {
                    model.openProfileInspector(profile)
                }
            }
            if let error = store.errorMessage { Text(error).foregroundStyle(.orange) }
        } footer: { Text(L10n.string("profiles.selection_help", fallback: "This selection applies to the next task.")) }
    }
}
