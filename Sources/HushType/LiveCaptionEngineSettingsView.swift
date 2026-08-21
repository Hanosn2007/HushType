import SwiftUI
import AppKit

/// View-model mirror of the cloud-relevant AppConfig fields. Holds in-memory
/// state during the Settings session and writes back to AppConfig on every
/// edit so the next Live Translated Caption start picks up the values.
///
/// Previously this also owned the local-vs-cloud engine picker; that was
/// removed when the product split landed (engine is now implied by which
/// menu the user invoked — Live Caption vs Live Translated Caption).
@MainActor
final class LiveCaptionEngineSettingsModel: ObservableObject {
    @Published var targetLanguage: String {
        didSet { AppConfig.shared.cloudTargetLanguage = targetLanguage }
    }
    @Published var showSourceLine: Bool {
        didSet { AppConfig.shared.cloudShowSourceLine = showSourceLine }
    }
    @Published var autoStopMinutes: Int {
        didSet { AppConfig.shared.cloudAutoStopMinutes = autoStopMinutes }
    }
    @Published var dailyCapDollars: Double {
        didSet { AppConfig.shared.cloudDailyCapDollars = dailyCapDollars }
    }

    @Published var keyStatusLine: String = ""
    @Published var todayUsageLine: String = ""

    init() {
        self.targetLanguage = AppConfig.shared.cloudTargetLanguage
        self.showSourceLine = AppConfig.shared.cloudShowSourceLine
        self.autoStopMinutes = AppConfig.shared.cloudAutoStopMinutes
        self.dailyCapDollars = AppConfig.shared.cloudDailyCapDollars
        refreshDerived()
    }

    /// Re-read derived display fields (key status, today's usage). Called on
    /// view appear and after Reset counter.
    func refreshDerived() {
        let status = OpenAIKeyStore.load()
        switch status {
        case .ok:
            keyStatusLine = L10n.string("settings.key.loaded", fallback: "✓ Key loaded")
        case .empty:
            keyStatusLine = L10n.string(
                "settings.key.empty_cloud_disabled",
                fallback: "Key empty — cloud features disabled"
            )
        case .unusualFormat:
            keyStatusLine = L10n.string(
                "settings.key.unusual_sk",
                fallback: "Key format unusual (does not start with sk-) — passing through anyway"
            )
        }
        // Today's usage is async; kick off a refresh and update when it lands.
        Task { [weak self] in
            let snap = await CloudUsageTracker.shared.snapshot()
            await MainActor.run {
                let minutes = Int(snap.sessionSeconds / 60.0)
                self?.todayUsageLine = L10n.plural(
                    "settings.usage.today",
                    count: minutes,
                    fallback: "Today's usage: %1$@ (%2$d min)",
                    arguments: [
                        CloudUsageTracker.formatDollars(snap.dayDollars),
                        Int32(minutes),
                    ]
                )
            }
        }
    }

    func resetCounter() {
        Task { [weak self] in
            await CloudUsageTracker.shared.resetDailyCounter()
            await MainActor.run { self?.refreshDerived() }
        }
    }

    func resetToDefaults() {
        autoStopMinutes = 60
        dailyCapDollars = 5.0
    }
}

struct LiveCaptionEngineSettingsView: View {
    @StateObject private var model = LiveCaptionEngineSettingsModel()

    private static var targetLanguages: [(value: String, label: String)] {[
        ("en", L10n.string("picker.autonym.en", fallback: "English")),
        ("zh-Hant", L10n.string("picker.target.traditional_chinese_autonym", fallback: "繁體中文")),
        ("zh-Hans", L10n.string("picker.target.simplified_chinese_autonym", fallback: "简体中文")),
        ("ja", L10n.string("picker.autonym.ja", fallback: "日本語")),
        ("ko", L10n.string("picker.autonym.ko", fallback: "한국어")),
        ("es", L10n.string("picker.autonym.es", fallback: "Español")),
        ("pt", L10n.string("picker.autonym.pt", fallback: "Português")),
        ("fr", L10n.string("picker.autonym.fr", fallback: "Français")),
        ("de", L10n.string("picker.autonym.de", fallback: "Deutsch")),
        ("ru", L10n.string("picker.autonym.ru", fallback: "Русский")),
        ("hi", L10n.string("picker.autonym.hi", fallback: "हिन्दी")),
        ("id", L10n.string("picker.autonym.id", fallback: "Bahasa Indonesia")),
        ("vi", L10n.string("picker.autonym.vi", fallback: "Tiếng Việt")),
        ("it", L10n.string("picker.autonym.it", fallback: "Italiano")),
    ]}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            Divider().padding(.vertical, 12)
            sectionCloudOptions
            Divider().padding(.vertical, 12)
            sectionGuardrails
            Divider().padding(.vertical, 12)
            sectionAPIKey
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 460, alignment: .topLeading)
        .onAppear { model.refreshDerived() }
    }

    // MARK: - Sections

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                L10n.string("menu.live_translated_caption", fallback: "Live Translated Caption"),
                systemImage: "globe"
            )
                .font(.headline)
            Text(L10n.string(
                "settings.translated_caption.description",
                fallback: "Real-time cloud translation via OpenAI's realtime translate endpoint. Audio streams Mac → OpenAI directly; HushType is never in the middle. Costs ~$2/hour against your own OpenAI API key."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sectionCloudOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L10n.string("settings.translated_caption.options", fallback: "Translation options"),
                systemImage: "captions.bubble"
            )
                .font(.headline)

            HStack {
                Text(L10n.string("settings.translated_caption.target", fallback: "Target language:"))
                Picker("", selection: $model.targetLanguage) {
                    ForEach(Self.targetLanguages, id: \.value) { lang in
                        Text(lang.label).tag(lang.value)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }

            Toggle(L10n.string(
                "settings.translated_caption.show_source",
                fallback: "Show source text above translation"
            ), isOn: $model.showSourceLine)
        }
    }

    private var sectionGuardrails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L10n.string("settings.cost_guardrails.title", fallback: "Cost guardrails"),
                systemImage: "dollarsign.circle"
            )
                .font(.headline)

            HStack {
                Text(L10n.string(
                    "settings.cost_guardrails.auto_stop",
                    fallback: "Auto-stop session after:"
                ))
                Stepper(value: Binding(
                    get: { model.autoStopMinutes },
                    set: { model.autoStopMinutes = max(5, min(480, $0)) }
                ), in: 5...480, step: 5) {
                    Text(L10n.plural(
                        "settings.duration.minutes",
                        count: model.autoStopMinutes,
                        fallback: "%1$d min",
                        arguments: [Int32(model.autoStopMinutes)]
                    ))
                        .frame(minWidth: 60, alignment: .trailing)
                        .monospacedDigit()
                }
            }

            HStack {
                Text(L10n.string(
                    "settings.cost_guardrails.daily_warning",
                    fallback: "Warn me when daily spend hits:"
                ))
                Stepper(value: Binding(
                    get: { model.dailyCapDollars },
                    set: { model.dailyCapDollars = max(0.5, min(100.0, $0)) }
                ), in: 0.5...100.0, step: 0.5) {
                    Text(CloudUsageTracker.formatDollars(model.dailyCapDollars))
                        .frame(minWidth: 60, alignment: .trailing)
                        .monospacedDigit()
                }
            }

            HStack {
                Text(model.todayUsageLine.isEmpty
                     ? L10n.string("settings.usage.placeholder", fallback: "Today's usage: —")
                     : model.todayUsageLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("common.button.reset_counter", fallback: "Reset counter")) {
                    model.resetCounter()
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            HStack {
                Spacer()
                Button(L10n.string("settings.reset_defaults", fallback: "Reset to defaults")) {
                    model.resetToDefaults()
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var sectionAPIKey: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L10n.string("settings.api_key.title", fallback: "API key"),
                systemImage: "key.fill"
            )
                .font(.headline)

            Text(OpenAIKeyStore.displayPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                Button(L10n.string(
                    "common.button.open_in_textedit",
                    fallback: "Open file in TextEdit"
                )) {
                    OpenAIKeyStore.openInDefaultEditor()
                    // After the user edits, refresh status when they return
                    // to settings.
                    model.refreshDerived()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }

            Text(model.keyStatusLine.isEmpty
                 ? L10n.string("settings.key.status.placeholder", fallback: "Status: —")
                 : L10n.format(
                    "settings.key.status_format",
                    "Status: %1$@",
                    arguments: [model.keyStatusLine]
                 ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
