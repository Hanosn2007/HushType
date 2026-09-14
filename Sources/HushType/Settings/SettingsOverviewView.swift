import AppKit
import SwiftUI

struct SettingsOverviewView: View {
    @ObservedObject var model: HushTypeSettingsModel
    @ObservedObject private var profiles = ProcessingProfileStore.shared
    @AppStorage(OverviewPreferences.developerModeKey) private var developerMode = false
    @State private var textStatus: LocalTextModelStatus?
    @State private var processMemory = MemoryUtils.formattedMemory()

    private var dictationTitle: String { L10n.string("settings.sidebar.dictation", fallback: "Dictation") }
    private var captionTitle: String { L10n.string("settings.sidebar.captions", fallback: "Captions") }
    private var none: String { L10n.string("overview.none", fallback: "None") }

    var body: some View {
        SettingsPage(
            subtitle: L10n.string(
                "settings.overview.subtitle",
                fallback: "View active tasks, input sources, loaded models, and items that need attention."
            )
        ) {
            Section {
                taskRow(title: dictationTitle, symbol: "mic.fill", use: .dictation,
                        state: model.dictationTaskState, enabled: model.canToggleDictation,
                        action: model.toggleDictation)
                taskRow(title: captionTitle, symbol: "captions.bubble.fill", use: .captions,
                        state: model.captionTaskState,
                        enabled: model.captionTaskState == .running || model.canStartCaptions,
                        action: model.toggleCaptions)
            }

            Section {
                if inputRows.isEmpty {
                    Text(none).foregroundStyle(.secondary)
                } else {
                    ForEach(inputRows) { row in
                        resourceRow(row.name, symbol: row.symbol, detail: row.users.joined(separator: " · "))
                    }
                }
            } header: {
                Text(L10n.string("overview.input_sources", fallback: "Input sources"))
            }

            Section {
                if model.loadedModelID == nil && textStatus?.isLoaded != true {
                    Text(none).foregroundStyle(.secondary)
                }
                if model.loadedModelID != nil {
                    resourceRow(model.overviewModelName, symbol: "waveform", detail: usageTitle(
                        model.dictationTaskState != .stopped || model.captionTaskState != .stopped))
                }
                if textStatus?.isLoaded == true {
                    resourceRow("Qwen3 4B", symbol: "text.bubble", detail: usageTitle(textStatus?.activity == .generating))
                }
            } header: {
                Text(L10n.string("overview.loaded_models", fallback: "Loaded models"))
            } footer: {
                // Physical footprint is process-wide, never attributed to an individual model.
                HStack {
                    Text(L10n.string("overview.app_memory", fallback: "HushType memory"))
                    Spacer()
                    Text(processMemory).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            if let message = attentionMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.permissionsComplete {
                        Button(L10n.string("common.button.open_settings", fallback: "Open Settings")) {
                            model.selection = .permissions
                        }
                    } else if model.loadedModelID == nil {
                        Button(L10n.string("settings.sidebar.model", fallback: "Model")) { model.selection = .model }
                    }
                }
            }

            if developerMode {
                Section {
                    LabeledContent(dictationTitle, value: model.statusTitle)
                    Text(model.statusDetail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LabeledContent(captionTitle, value: captionStage)
                    if let textStatus {
                        LabeledContent(L10n.string("settings.local_text.model.title", fallback: "Local Text Model"),
                                       value: String(describing: textStatus.activity))
                    }
                    LabeledContent(L10n.string("settings.general.version", fallback: "Version"), value: model.appVersionDisplay)
                } header: { SettingsDebugDivider() }
            }
        }
        .task {
            while !Task.isCancelled {
                model.refreshOverviewResources()
                if case .success(let service) = LocalTextResources.service {
                    textStatus = await service.status()
                }
                processMemory = MemoryUtils.formattedMemory()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }

    private func taskRow(title: String, symbol: String, use: ProcessingProfileStore.Use,
                         state: OverviewTaskState, enabled: Bool, action: @escaping () -> Void) -> some View {
        let color: Color = state == .stopped ? .red : .green
        let active = use == .dictation ? model.activeDictationProfile : model.activeCaptionProfile
        let profile = state == .stopped ? profiles.selected(use) : active
        let name = profile?.name ?? ""
        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(color, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Button(L10n.string("overview.configuration", fallback: "Configuration:") + " " + name) {
                    if let profile { model.openProfileInspector(profile) }
                }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            OverviewTaskButton(taskName: title, state: state, enabled: enabled, action: action)
        }
        .frame(minHeight: 44)
    }

    private func resourceRow(_ name: String, symbol: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15)).foregroundStyle(.secondary)
                .frame(width: 20).accessibilityHidden(true)
            Text(name).textSelection(.enabled)
            Spacer(minLength: 12)
            Text(detail).foregroundStyle(.secondary)
        }
    }

    private func usageTitle(_ busy: Bool) -> String {
        busy ? L10n.string("overview.in_use", fallback: "In use") : L10n.string("overview.idle", fallback: "Idle")
    }

    private struct InputRow: Identifiable {
        let id: String
        let name: String
        let symbol: String
        var users: [String]
    }

    private var inputRows: [InputRow] {
        var rows: [String: InputRow] = [:]
        func add(_ profile: ProcessingProfile?, user: String) {
            guard let input = profile?.input else { return }
            let mic = input.kind == .microphone
            let key = input.kind.rawValue + ":" + (mic ? input.device : input.bundleID)
            if rows[key] == nil { rows[key] = InputRow(id: key, name: input.displayName, symbol: mic ? "mic" : "app.dashed", users: []) }
            rows[key]?.users.append(user)
        }
        if case .recording = model.appState { add(model.activeDictationProfile, user: dictationTitle) }
        if model.isCaptionActive, !model.isCaptionStarting { add(model.activeCaptionProfile, user: captionTitle) }
        return rows.values.sorted { $0.id < $1.id }
    }

    private var attentionMessage: String? {
        if case .error(let message) = model.appState { return message }
        if !model.permissionsComplete {
            return L10n.string("settings.overview.permissions_needed.detail", fallback: "Allow Accessibility and Microphone in Permissions to use voice input.")
        }
        return nil
    }

    private var captionStage: String {
        if model.isCaptionFinishing { return L10n.string("overview.finishing", fallback: "Finishing") }
        if model.isCaptionStarting { return L10n.string("settings.captions.status.starting", fallback: "Starting") }
        return model.isCaptionActive ? L10n.string("overview.running", fallback: "Running") : none
    }
}

struct SettingsTaskControlSection: View {
    let taskName: String
    let statusLabel: String
    let status: String
    let state: OverviewTaskState
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Section {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(status)
                }
                Spacer(minLength: 12)
                OverviewTaskButton(
                    taskName: taskName,
                    state: state,
                    enabled: enabled,
                    action: action
                )
            }
            .frame(minHeight: 40)
        }
    }
}

struct OverviewTaskButton: View {
    let taskName: String
    let state: OverviewTaskState
    let enabled: Bool
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    private var stop: String { L10n.string("settings.captions.stop", fallback: "Stop") }
    private var title: String {
        switch state {
        case .stopped: L10n.string("overview.start", fallback: "Start")
        case .running: hovered || focused ? stop : L10n.string("overview.running", fallback: "Running")
        case .finishing: stop
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if state == .finishing { ProgressView().controlSize(.small) }
                else { Color.clear }
            }
            .frame(width: 16, height: 16)
            Button(action: action) {
                Text(title)
                    .frame(width: 66)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .disabled(!enabled || state == .finishing)
            .focused($focused)
            .onHover { hovered = $0 }
            .accessibilityLabel(taskName + ": " + (state == .running ? stop : title))
            .accessibilityValue(state == .finishing ? L10n.string("overview.finishing", fallback: "Finishing") : title)
        }
    }
}
