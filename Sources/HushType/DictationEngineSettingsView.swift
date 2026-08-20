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
    @Published var usageLine = "Today's cloud usage: —"
    @Published var openAIKeyStatus = "Status: —"
    @Published var geminiKeyStatus = "Status: —"

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
        case .ok: return "Status: ✓ Key loaded"
        case .empty: return "Status: Key empty — OpenAI cloud features disabled"
        case .unusualFormat: return "Status: Key format unusual — passing through anyway"
        }
    }

    private static func geminiStatusLine(_ status: GeminiKeyStore.LoadStatus) -> String {
        switch status {
        case .ok: return "Status: ✓ Key loaded"
        case .empty: return "Status: Key empty — Gemini cloud dictation disabled"
        case .unusualFormat: return "Status: Key format unusual — passing through anyway"
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
            Label("Dictation Engine", systemImage: "mic.fill")
                .font(.headline)
            Text("Choose where speech becomes text. Local is private and free. Cloud engines send audio directly to the provider using your own API key — no relay, no HushType server in the middle.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sectionEngine: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Engine", systemImage: "cpu").font(.headline)

            Picker("", selection: $model.engine) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local (Qwen3-ASR)")
                    Text("Private · Free · ~2.1 GB RAM when loaded")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(AppConfig.DictationEngine.local)

                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenAI Cloud")
                    Text("\(rateText(model.openAIRate)) · No model RAM")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(AppConfig.DictationEngine.openai)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Gemini Cloud")
                    Text("Free tier; metered at \(rateText(model.geminiRate)) · No model RAM")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(AppConfig.DictationEngine.gemini)
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)

            HStack(spacing: 8) {
                Text("OpenAI model:")
                Picker("", selection: $model.openAIModel) {
                    Text("gpt-4o-mini-transcribe (recommended)").tag("gpt-4o-mini-transcribe")
                    Text("gpt-transcribe").tag("gpt-transcribe")
                }
                .labelsHidden()
                .disabled(model.engine != .openai)
            }

            HStack(spacing: 8) {
                Text("Gemini model:")
                Picker("", selection: $model.geminiModel) {
                    Text("gemini-3.7-flash (quality)").tag("gemini-3.7-flash")
                    Text("gemini-3.5-flash-lite (budget)").tag("gemini-3.5-flash-lite")
                }
                .labelsHidden()
                .disabled(model.engine != .gemini)
            }

            Text("While a cloud engine is selected the speech model stays unloaded. The iOS companion server always uses the local model.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sectionGuardrails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Cost guardrails", systemImage: "dollarsign.circle").font(.headline)

            HStack {
                Text("Warn me when daily spend hits:")
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
                Button("Reset counter") { model.resetCounter() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var sectionAPIKeys: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("API keys", systemImage: "key.fill").font(.headline)
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
                Button("Open file in TextEdit") { model.openKeyFile(provider: providerID) }
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
        String(format: "$%.3f/min", rate)
    }
}
