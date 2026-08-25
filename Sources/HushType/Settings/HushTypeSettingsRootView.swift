import AVFoundation
import SwiftUI

struct HushTypeSettingsRootView: View {
    @ObservedObject var model: HushTypeSettingsModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.visibleSections) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 270)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .overview: SettingsOverviewView(model: model)
        case .dictation: SettingsDictationView(model: model)
        case .model: SettingsModelView(model: model)
        case .dictionary: SettingsDictionaryView(model: model)
        case .permissions: SettingsPermissionsView(model: model)
        case .general: SettingsGeneralView(model: model)
        }
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 26, weight: .semibold))
                    Text(subtitle).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
                Spacer(minLength: 16)
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(28)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct SettingsOverviewView: View {
    @ObservedObject var model: HushTypeSettingsModel

    var body: some View {
        SettingsPage(
            title: L10n.string("settings.overview.title", fallback: "Overview"),
            subtitle: L10n.string("settings.overview.subtitle", fallback: "A quick view of HushType and its local speech model.")
        ) {
            SettingsCard {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: model.statusSymbol)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(model.statusTint)
                        .frame(width: 38)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.statusTitle).font(.headline)
                        Text(model.statusDetail).font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 5) {
                            Text(model.overviewModelLabel)
                            Text(model.overviewModelName)
                                .fontWeight(.medium)
                        }
                        .font(.subheadline)
                        .padding(.top, 3)
                        if model.hasPendingModelChange {
                            Text(L10n.format(
                                "settings.overview.pending_model_change",
                                "%1$@ is selected and will run after the next model load.",
                                arguments: [model.selectedModelName]
                            ))
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 12)
                    modelAction
                }
            }

            if !model.permissionsComplete {
                Button {
                    model.selection = .permissions
                } label: {
                    SettingsCard {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.string("settings.overview.permissions_needed.title", fallback: "Permissions need attention"))
                                    .font(.headline)
                                Text(L10n.string("settings.overview.permissions_needed.detail", fallback: "Allow Accessibility and Microphone in Permissions to use voice input."))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.string("settings.overview.how_to.title", fallback: "How to dictate"), systemImage: "keyboard")
                        .font(.headline)
                    Text(L10n.string("settings.overview.how_to.detail", fallback: "Press F5 to start recording, then press F5 again to transcribe and insert at the cursor."))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var modelAction: some View {
        switch model.modelControl {
        case .stopDownload:
            Button(L10n.string("settings.model.stop", fallback: "Stop")) { model.stopModelDownload() }
                .buttonStyle(.bordered)
        case .unload:
            Button(L10n.string("settings.model.unload", fallback: "Unload")) { model.unloadModel() }
                .buttonStyle(.bordered)
        case .load:
            Button(L10n.string("settings.model.load", fallback: "Load Model")) { model.loadOrReloadModel() }
                .buttonStyle(.borderedProminent)
        case .none:
            EmptyView()
        }
    }
}

private struct SettingsDictationView: View {
    @ObservedObject var model: HushTypeSettingsModel

    var body: some View {
        SettingsPage(
            title: L10n.string("settings.dictation.title", fallback: "Dictation"),
            subtitle: L10n.string("settings.dictation.window_subtitle", fallback: "Configure local recognition and output cleanup.")
        ) {
            if model.currentDictationEngine == .local {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L10n.string("settings.dictation.local_engine", fallback: "Local (Qwen3-ASR)"), systemImage: "cpu")
                            .font(.headline)
                        Text(L10n.string("settings.dictation.local_privacy", fallback: "Speech recognition runs locally on this Mac. Audio is not uploaded."))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                SettingsCard {
                    DictationEngineSettingsView(onSwitchEngine: model.switchDictationEngine)
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.string("settings.dictation.output", fallback: "Recognition and output")).font(.headline)
                    Picker(L10n.string("menu.speech_to_text_language", fallback: "Speech-to-Text Language"), selection: $model.speechLanguage) {
                        Text(L10n.string("menu.choice.auto", fallback: "Auto")).tag("auto")
                        Text(L10n.string("picker.autonym.en", fallback: "English")).tag("english")
                        Text(L10n.string("picker.autonym.zh", fallback: "中文")).tag("chinese")
                        Text(L10n.string("picker.autonym.ja", fallback: "日本語")).tag("japanese")
                    }
                    Toggle(L10n.string("settings.general.number_conversion", fallback: "Convert Chinese numbers to digits"), isOn: $model.numberConversionEnabled)
                    Toggle(L10n.string("settings.dictation.traditional_chinese", fallback: "Convert Simplified Chinese output to Traditional Chinese"), isOn: $model.chineseConversionEnabled)
                    Picker(L10n.string("settings.general.punctuation", fallback: "Punctuation cleanup"), selection: $model.punctuationMode) {
                        Text(L10n.string("settings.general.punctuation.soft", fallback: "Soft")).tag(PunctuationMode.soft)
                        Text(L10n.string("settings.general.punctuation.hard", fallback: "Strict")).tag(PunctuationMode.hard)
                        Text(L10n.string("settings.general.punctuation.off", fallback: "Off")).tag(PunctuationMode.off)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
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
            title: L10n.string("settings.model.title", fallback: "Local Model"),
            subtitle: L10n.string("settings.model.subtitle", fallback: "Manage the Qwen3-ASR model stored in memory for local dictation.")
        ) {
            SettingsCard {
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

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.string("settings.model.installed_picker", fallback: "Installed models")).font(.headline)
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
                    Text(L10n.string(
                        "settings.model.apply_next_load",
                            fallback: "Model changes take effect the next time it loads."
                    ))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.string("settings.model.library.title", fallback: "Model Library"))
                            .font(.headline)
                        Text(L10n.string(
                            "settings.model.library.subtitle",
                            fallback: "Install models before selecting them. Downloads continue if this window is closed."
                        ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }

                    ForEach(Array(LocalModelCatalog.models.enumerated()), id: \.element.id) { index, descriptor in
                        if index > 0 { Divider() }
                        modelLibraryRow(descriptor)
                    }
                }
            }
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
        case .notInstalled, .failed:
            Button(L10n.string("settings.model.install", fallback: "Install")) {
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

private struct SettingsDictionaryView: View {
    @ObservedObject var model: HushTypeSettingsModel

    var body: some View {
        SettingsPage(
            title: L10n.string("settings.dictionary.title", fallback: "Dictionary"),
            subtitle: L10n.string("settings.dictionary.subtitle", fallback: "Correct names, technical terms, and recurring transcription mistakes.")
        ) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.string("settings.dictionary.entries", fallback: "Customized Dictionary")).font(.headline)
                    Text(dictionaryDetail).foregroundStyle(.secondary)
                    Button(L10n.string("settings.dictionary.open", fallback: "Open Dictionary…")) { model.openDictionary() }
                        .buttonStyle(.borderedProminent)
                    Text(L10n.string("settings.dictionary.help", fallback: "Use one rule per line: what you say -> what gets typed. Changes apply to the next transcription."))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var dictionaryDetail: String {
        guard DictionaryReplacer.fileExists else {
            return L10n.string("settings.dictionary.empty", fallback: "No dictionary file yet.")
        }
        let count = DictionaryReplacer.entryCount
        return L10n.plural("settings.dictionary.entry_count", count, fallback: count == 1 ? "%1$ld entry loaded" : "%1$ld entries loaded")
    }
}

private struct SettingsPermissionsView: View {
    @ObservedObject var model: HushTypeSettingsModel

    var body: some View {
        SettingsPage(
            title: L10n.string("settings.permissions.title", fallback: "Permissions"),
            subtitle: L10n.string("settings.permissions.subtitle", fallback: "HushType needs these permissions for its global hotkey and microphone input.")
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

            if model.needsPermissionRestart {
                SettingsCard {
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
                SettingsCard {
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
        SettingsCard {
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

    var body: some View {
        SettingsPage(
            title: L10n.string("settings.general.title", fallback: "General"),
            subtitle: L10n.string("settings.general.subtitle", fallback: "Adjust how HushType presents and cleans up dictation.")
        ) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L10n.string("settings.general.floating_overlay", fallback: "Show the floating recording overlay"), isOn: $model.floatingOverlayEnabled)
                    Toggle(
                        L10n.string(
                            "settings.general.release_f5_when_unloaded",
                            fallback: "Return F5 to macOS after unloading the model"
                        ),
                        isOn: $model.releaseF5WhenModelUnloaded
                    )
                    Toggle(L10n.string("settings.general.text_polish", fallback: "Enable text polishing"), isOn: $model.textPolishEnabled)
                }
            }
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.string("menu.interface_language", fallback: "Interface Language")).font(.headline)
                    Picker(L10n.string("menu.interface_language", fallback: "Interface Language"), selection: $model.interfaceLanguageRaw) {
                        Text(L10n.string("menu.interface_language.follow_system", fallback: "Follow System")).tag(InterfaceLanguage.system.rawValue)
                        Text(L10n.string("menu.interface_language.english", fallback: "English")).tag(InterfaceLanguage.english.rawValue)
                        Text(L10n.string("menu.interface_language.simplified_chinese", fallback: "简体中文")).tag(InterfaceLanguage.simplifiedChinese.rawValue)
                        Text(L10n.string("menu.interface_language.traditional_chinese_taiwan", fallback: "繁體中文（台灣）")).tag(InterfaceLanguage.traditionalChineseTaiwan.rawValue)
                    }
                    Text(L10n.string("menu.interface_language.applied_next_launch", fallback: "Changes apply the next time HushType launches."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private extension HushTypeSettingsModel {
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
        case .recording: L10n.string("status.recording", fallback: "Listening")
        case .transcribing: L10n.string("status.transcribing", fallback: "Transcribing")
        case .polishing: L10n.string("status.polishing", fallback: "Polishing text")
        case .error: L10n.string("status.error", fallback: "Needs attention")
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
