import SwiftUI

/// Selected-text controls and the optional local text-model manager embedded in
/// the existing Models settings page.
struct SettingsLocalTextModelView: View {
    @ObservedObject var model: HushTypeSettingsModel
    @AppStorage(LocalTextPreferences.selectionTargetKey) private var selectionTarget = "automatic"

    var body: some View {
        configurationSection

        switch LocalTextResources.service {
        case .success(let service):
            SettingsLocalTextModelManagementView(service: service)
        case .failure(let error):
            Section {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } header: {
                Text(L10n.string(
                    "settings.local_text.model.title",
                    fallback: "Local Text Model"
                ))
            }
        }
    }

    private var configurationSection: some View {
        Section {
            Toggle(
                L10n.string(
                    "settings.local_text.polish.enabled",
                    fallback: "Proofread selected text"
                ),
                isOn: $model.textPolishEnabled
            )
            Toggle(
                L10n.string(
                    "settings.local_text.translation.enabled",
                    fallback: "Translate selected text"
                ),
                isOn: $model.textTranslationEnabled
            )
            Picker(
                L10n.string(
                    "settings.local_text.selection_target",
                    fallback: "Translation target"
                ),
                selection: $selectionTarget
            ) {
                Text(L10n.string(
                    "settings.local_text.target.automatic",
                    fallback: "Automatic"
                ))
                .tag("automatic")
                ForEach(LocalTextLanguage.allCases) { language in
                    Text(language.title).tag(language.rawValue)
                }
            }
            .pickerStyle(.menu)
            .disabled(!model.textTranslationEnabled)

            Text(L10n.string(
                "settings.local_text.shortcuts.help",
                fallback: "Choose the proofreading and translation shortcuts in Shortcuts on the left."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
            Text(L10n.string(
                "settings.local_text.selected_text.title",
                fallback: "Selected Text"
            ))
        }
        .onChange(of: selectionTarget) { _, _ in
            NotificationCenter.default.post(name: LocalTextPreferences.didChange, object: nil)
        }
        .onChange(of: model.textTranslationEnabled) { _, _ in
            NotificationCenter.default.post(name: LocalTextPreferences.didChange, object: nil)
        }
    }
}

private struct SettingsLocalTextModelManagementView: View {
    @StateObject private var controller: LocalTextModelController
    @AppStorage(LocalTextPreferences.captionTranslationKey) private var translatesCaptions = false

    init(service: LocalTextModelService) {
        _controller = StateObject(wrappedValue: LocalTextModelController(service: service))
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalTextModelDescriptor.qwen3FourBit.displayName)
                            .font(.body.weight(.medium))
                        Text(L10n.string(
                            "settings.local_text.model.detail",
                            fallback: "Optional 4-bit model shared by proofreading, selected-text translation, and translated captions. The download is about 2.3 GB. Runtime memory changes with input length and can be higher than the download size."
                        ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    actionControl
                }

                statusLabel

                if case .downloading(let progress) = controller.status.activity {
                    ProgressView(value: progress.fractionCompleted)
                    Text(downloadDetail(progress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = controller.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text(L10n.string(
                "settings.local_text.model.title",
                fallback: "Local Text Model"
            ))
        } footer: {
            Text(L10n.string(
                "settings.local_text.model.manual_help",
                fallback: "The model is never downloaded or loaded automatically from this page. Text operations can load an installed model when needed."
            ))
        }
        .task {
            while !Task.isCancelled {
                await controller.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private var actionControl: some View {
        switch controller.status.activity {
        case .downloading, .loading, .generating:
            Button(L10n.string("common.button.cancel", fallback: "Cancel")) {
                translatesCaptions = false
                NotificationCenter.default.post(name: LocalTextPreferences.didChange, object: nil)
                Task { await controller.cancel() }
            }
            .buttonStyle(.bordered)
        case .unloading:
            ProgressView().controlSize(.small)
        case .idle, .failed:
            if controller.status.isLoaded {
                Button(L10n.string(
                    "settings.local_text.model.unload",
                    fallback: "Unload from Memory"
                )) {
                    unload()
                }
                .buttonStyle(.bordered)
            } else {
                switch controller.status.installation {
                case .installed:
                    Button(L10n.string(
                        "settings.local_text.model.load",
                        fallback: "Load Model"
                    )) {
                        Task { await controller.load() }
                    }
                    .buttonStyle(.borderedProminent)
                case .notInstalled:
                    Button(L10n.string(
                        "settings.local_text.model.download",
                        fallback: "Download 2.3 GB"
                    )) {
                        Task { await controller.download() }
                    }
                    .buttonStyle(.borderedProminent)
                case .incomplete:
                    Button(L10n.string(
                        "settings.local_text.model.resume_download",
                        fallback: "Resume Download"
                    )) {
                        Task { await controller.download() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch controller.status.activity {
        case .downloading:
            Label(
                L10n.string("settings.local_text.model.downloading", fallback: "Downloading"),
                systemImage: "arrow.down.circle.fill"
            )
            .foregroundStyle(.blue)
        case .loading:
            Label(
                L10n.string("settings.local_text.model.loading", fallback: "Loading into memory"),
                systemImage: "memorychip"
            )
            .foregroundStyle(.secondary)
        case .generating:
            Label(
                L10n.string("settings.local_text.model.in_use", fallback: "Processing text"),
                systemImage: "ellipsis.circle"
            )
            .foregroundStyle(.secondary)
        case .unloading:
            Label(
                L10n.string("settings.local_text.model.unloading", fallback: "Unloading"),
                systemImage: "arrow.down.right.and.arrow.up.left"
            )
            .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .idle:
            if controller.status.isLoaded {
                Label(
                    L10n.string("settings.local_text.model.loaded", fallback: "Loaded in memory"),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            } else {
                switch controller.status.installation {
                case .installed:
                    Label(
                        L10n.string("settings.local_text.model.installed", fallback: "Downloaded"),
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(.green)
                case .notInstalled:
                    Label(
                        L10n.string("settings.local_text.model.not_installed", fallback: "Not downloaded"),
                        systemImage: "square.and.arrow.down"
                    )
                    .foregroundStyle(.secondary)
                case .incomplete(let missingFiles):
                    Label(
                        L10n.format(
                            "settings.local_text.model.incomplete",
                            "Incomplete download · %1$d files missing",
                            arguments: [Int32(missingFiles.count)]
                        ),
                        systemImage: "exclamationmark.circle"
                    )
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private func unload() {
        translatesCaptions = false
        NotificationCenter.default.post(name: LocalTextPreferences.didChange, object: nil)
        Task { await controller.unload() }
    }

    private func downloadDetail(_ progress: LocalTextModelDownloadProgress) -> String {
        let percent = Int((progress.fractionCompleted * 100).rounded())
        guard let completed = progress.completedBytes, let total = progress.totalBytes else {
            return L10n.format(
                "settings.local_text.model.download_percent",
                "%1$d%%",
                arguments: [Int32(percent)]
            )
        }
        return L10n.format(
            "settings.local_text.model.download_progress",
            "%1$d%% · %2$@ / %3$@",
            arguments: [
                Int32(percent),
                ByteCountFormatter.string(fromByteCount: completed, countStyle: .file),
                ByteCountFormatter.string(fromByteCount: total, countStyle: .file),
            ]
        )
    }
}
