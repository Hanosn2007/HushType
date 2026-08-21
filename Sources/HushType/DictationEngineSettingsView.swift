import SwiftUI
import AppKit

extension Notification.Name {
    static let hushTypeDictationEngineDidChange = Notification.Name(
        "com.felix.hushtype.dictationEngineDidChange"
    )
}

@MainActor
final class DictationEngineSettingsModel: ObservableObject {
    @Published var engine: AppConfig.DictationEngine {
        didSet {
            guard engine != oldValue else { return }
            onSwitchEngine(engine)
        }
    }
    @Published var openAIModel: String {
        didSet { AppConfig.shared.cloudDictationModelOpenAI = openAIModel }
    }
    @Published var geminiModel: String {
        didSet { AppConfig.shared.cloudDictationModelGemini = geminiModel }
    }
    @Published var dailyCap: Double {
        didSet { AppConfig.shared.cloudDailyCapDollars = dailyCap }
    }
    @Published var usageLine = L10n.string(
        "settings.daily_usage.placeholder",
        fallback: "Today's cloud usage: —"
    )
    @Published var openAIKeyStatus = L10n.string(
        "settings.key.status.placeholder",
        fallback: "Status: —"
    )
    @Published var geminiKeyStatus = L10n.string(
        "settings.key.status.placeholder",
        fallback: "Status: —"
    )

    private let onSwitchEngine: (AppConfig.DictationEngine) -> Void

    init(onSwitchEngine: @escaping (AppConfig.DictationEngine) -> Void) {
        self.onSwitchEngine = onSwitchEngine
        engine = AppConfig.shared.dictationEngine
        openAIModel = AppConfig.shared.cloudDictationModelOpenAI
        geminiModel = AppConfig.shared.cloudDictationModelGemini
        dailyCap = AppConfig.shared.cloudDailyCapDollars
        refreshDerived()
    }

    var openAIRate: Double {
        CloudUsageTracker.dictationRate(provider: .openai, model: openAIModel)
    }

    var geminiRate: Double {
        CloudUsageTracker.dictationRate(provider: .gemini, model: geminiModel)
    }

    func refreshDerived() {
        engine = AppConfig.shared.dictationEngine
        openAIModel = AppConfig.shared.cloudDictationModelOpenAI
        geminiModel = AppConfig.shared.cloudDictationModelGemini
        dailyCap = AppConfig.shared.cloudDailyCapDollars
        openAIKeyStatus = Self.openAIStatusLine(OpenAIKeyStore.load())
        geminiKeyStatus = Self.geminiStatusLine(GeminiKeyStore.load())
        Task { [weak self] in
            let snapshot = await CloudUsageTracker.shared.snapshot()
            await MainActor.run {
                self?.usageLine = CloudUsageTracker.formatDailyBreakdown(snapshot)
            }
        }
    }

    func resetCounter() {
        Task { [weak self] in
            await CloudUsageTracker.shared.resetDailyCounter()
            await MainActor.run { self?.refreshDerived() }
        }
    }

    func openKeyFile(provider: CloudUsageTracker.Provider) {
        switch provider {
        case .openai: OpenAIKeyStore.openInDefaultEditor()
        case .gemini: GeminiKeyStore.openInDefaultEditor()
        }
        refreshDerived()
    }

    private static func openAIStatusLine(_ status: OpenAIKeyStore.LoadStatus) -> String {
        switch status {
        case .ok:
            return L10n.string("settings.key.status.loaded", fallback: "Status: ✓ Key loaded")
        case .empty:
            return L10n.string(
                "settings.key.status.openai_empty",
                fallback: "Status: Key empty — OpenAI cloud features disabled"
            )
        case .unusualFormat:
            return L10n.string(
                "settings.key.status.unusual",
                fallback: "Status: Key format unusual — passing through anyway"
            )
        }
    }

    private static func geminiStatusLine(_ status: GeminiKeyStore.LoadStatus) -> String {
        switch status {
        case .ok:
            return L10n.string("settings.key.status.loaded", fallback: "Status: ✓ Key loaded")
        case .empty:
            return L10n.string(
                "settings.key.status.gemini_empty",
                fallback: "Status: Key empty — Gemini cloud dictation disabled"
            )
        case .unusualFormat:
            return L10n.string(
                "settings.key.status.unusual",
                fallback: "Status: Key format unusual — passing through anyway"
            )
        }
    }
}

struct DictationEngineSettingsView: View {
    @StateObject private var model: DictationEngineSettingsModel

    init(onSwitchEngine: @escaping (AppConfig.DictationEngine) -> Void) {
        _model = StateObject(
            wrappedValue: DictationEngineSettingsModel(onSwitchEngine: onSwitchEngine)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            Divider().padding(.vertical, 12)
            sectionEngine
            Divider().padding(.vertical, 12)
            sectionGuardrails
            Divider().padding(.vertical, 12)
            sectionAPIKeys
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 460, alignment: .topLeading)
        .onAppear { model.refreshDerived() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshDerived()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hushTypeDictationEngineDidChange)) { _ in
            model.refreshDerived()
        }
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                L10n.string("menu.dictation_engine", fallback: "Dictation Engine"),
                systemImage: "mic.fill"
            )
                .font(.headline)
            Text(L10n.string(
                "settings.dictation.description",
                fallback: "Choose where speech becomes text. Local is private and free. Cloud engines send audio directly to the provider using your own API key — no relay, no HushType server in the middle."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sectionEngine: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L10n.string("settings.dictation.engine_section", fallback: "Engine"),
                systemImage: "cpu"
            ).font(.headline)

            Picker("", selection: $model.engine) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("menu.engine.local_qwen", fallback: "Local (Qwen3-ASR)"))
                    Text(L10n.string(
                        "settings.engine.local.detail",
                        fallback: "Private · Free · ~2.1 GB RAM when loaded"
                    ))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(AppConfig.DictationEngine.local)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("menu.engine.openai_cloud", fallback: "OpenAI Cloud"))
                    Text(L10n.format(
                        "settings.engine.cloud.detail",
                        "%1$@ · No model RAM",
                        arguments: [rateText(model.openAIRate)]
                    ))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(AppConfig.DictationEngine.openai)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("menu.engine.gemini_cloud", fallback: "Gemini Cloud"))
                    Text(L10n.format(
                        "settings.engine.gemini.detail",
                        "%1$@ · No model RAM",
                        arguments: [rateText(model.geminiRate)]
                    ))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(AppConfig.DictationEngine.gemini)
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)

            HStack(spacing: 8) {
                Text(L10n.string("settings.engine.openai_model", fallback: "OpenAI model:"))
                Picker("", selection: $model.openAIModel) {
                    Text(L10n.string(
                        "settings.model.recommended",
                        fallback: "gpt-4o-mini-transcribe (recommended)"
                    )).tag("gpt-4o-mini-transcribe")
                    Text(L10n.string(
                        "settings.model.gpt_transcribe",
                        fallback: "gpt-transcribe"
                    )).tag("gpt-transcribe")
                }
                .labelsHidden()
                .disabled(model.engine != .openai)
            }

            HStack(spacing: 8) {
                Text(L10n.string("settings.engine.gemini_model", fallback: "Gemini model:"))
                Picker("", selection: $model.geminiModel) {
                    Text(L10n.string(
                        "settings.model.quality",
                        fallback: "gemini-3.7-flash (quality)"
                    )).tag("gemini-3.7-flash")
                    Text(L10n.string(
                        "settings.model.budget",
                        fallback: "gemini-3.5-flash-lite (budget)"
                    )).tag("gemini-3.5-flash-lite")
                }
                .labelsHidden()
                .disabled(model.engine != .gemini)
            }

            Text(L10n.string(
                "settings.engine.cloud_unloads_local",
                fallback: "While a cloud engine is selected the speech model stays unloaded. The iOS companion server always uses the local model."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sectionGuardrails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L10n.string("settings.daily_spend.title", fallback: "Daily spend warning"),
                systemImage: "dollarsign.circle"
            ).font(.headline)

            HStack {
                Text(L10n.string(
                    "settings.daily_spend.block_at",
                    fallback: "Block new cloud uploads at:"
                ))
                Stepper(value: $model.dailyCap, in: 0.5...100.0, step: 0.5) {
                    Text(CloudUsageTracker.formatDollars(model.dailyCap))
                        .frame(minWidth: 60, alignment: .trailing)
                        .monospacedDigit()
                }
            }

            HStack {
                Text(model.usageLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L10n.string("common.button.reset_counter", fallback: "Reset counter")) {
                    model.resetCounter()
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var sectionAPIKeys: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L10n.string("settings.api_keys.title", fallback: "API keys"),
                systemImage: "key.fill"
            ).font(.headline)
            apiKeySubsection(
                provider: "OpenAI",
                path: OpenAIKeyStore.displayPath,
                status: model.openAIKeyStatus,
                providerID: .openai
            )
            apiKeySubsection(
                provider: "Gemini",
                path: GeminiKeyStore.displayPath,
                status: model.geminiKeyStatus,
                providerID: .gemini
            )
        }
    }

    private func apiKeySubsection(
        provider: String,
        path: String,
        status: String,
        providerID: CloudUsageTracker.Provider
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(provider).font(.body.bold())
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button(L10n.string(
                    "common.button.open_in_textedit",
                    fallback: "Open file in TextEdit"
                )) { model.openKeyFile(provider: providerID) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Spacer()
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func rateText(_ rate: Double) -> String {
        L10n.format("format.usd_rate_per_minute", "$%1$.3f/min", arguments: [rate])
    }
}
